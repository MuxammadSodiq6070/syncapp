package main

import (
	"bytes"
	"context"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"
)

const (
	maxMediaBytes  = 50*1024*1024 + 1024 // 50 MB plaintext plus the AEAD header
	mediaTokenTTL  = 10 * time.Minute
	minFreeDisk    = 1 << 30
	maxInFlight    = 32
	blobHTTPLimit  = 10 * time.Minute
	blobDeleteSize = 500
)

var (
	errMediaTooLarge = errors.New("too_large")
	errMediaEmpty    = errors.New("empty")
	errMediaQuota    = errors.New("media_quota")
	errBlobNotFound  = errors.New("not_found")
)

// BlobStore holds opaque encrypted blobs. Nothing here can read them.
type BlobStore interface {
	Put(ctx context.Context, id string, f *os.File, size int64) error
	Get(ctx context.Context, id string) (io.ReadCloser, int64, error)
	Delete(ctx context.Context, ids []string) error
	HasRoom(size int64) bool
}

// MediaLimits bound what one identity, and everyone together, can keep stored.
type MediaLimits struct {
	PerOwner int64
	Total    int64
	TTL      time.Duration
}

type MediaStore struct {
	blobs  BlobStore
	store  *Store
	limits MediaLimits
	spool  string
	secret []byte
	slots  chan struct{}
}

func NewMediaStore(store *Store, blobs BlobStore, limits MediaLimits, spool string) (*MediaStore, error) {
	if err := os.MkdirAll(spool, 0o700); err != nil {
		return nil, err
	}
	secret := make([]byte, 32)
	if _, err := rand.Read(secret); err != nil {
		return nil, err
	}
	return &MediaStore{blobs: blobs, store: store, limits: limits, spool: spool, secret: secret, slots: make(chan struct{}, maxInFlight)}, nil
}

func (m *MediaStore) sign(payload string) string {
	h := hmac.New(sha256.New, m.secret)
	h.Write([]byte(payload))
	return hex.EncodeToString(h.Sum(nil))
}

// Token authorizes uploads for a short time. Tokens die with the process, by design.
func (m *MediaStore) Token(user string) string {
	payload := user + "." + strconv.FormatInt(time.Now().Add(mediaTokenTTL).Unix(), 10)
	return payload + "." + m.sign(payload)
}

// CheckToken returns the identity a valid token was issued to.
func (m *MediaStore) CheckToken(tok string) (string, bool) {
	i := strings.LastIndexByte(tok, '.')
	if i < 0 {
		return "", false
	}
	payload, sig := tok[:i], tok[i+1:]
	if !hmac.Equal([]byte(sig), []byte(m.sign(payload))) {
		return "", false
	}
	j := strings.LastIndexByte(payload, '.')
	if j < 0 {
		return "", false
	}
	exp, err := strconv.ParseInt(payload[j+1:], 10, 64)
	if err != nil || time.Now().Unix() >= exp {
		return "", false
	}
	return payload[:j], true
}

func validMediaID(id string) bool {
	if len(id) != 32 || id != strings.ToLower(id) {
		return false
	}
	_, err := hex.DecodeString(id)
	return err == nil
}

// usage returns what owner has stored and what everyone has.
func (m *MediaStore) usage(ctx context.Context, owner string) (mine, total int64, err error) {
	err = m.store.db.QueryRow(ctx, `
		SELECT coalesce(sum(bytes) FILTER (WHERE owner = $1), 0)::bigint, coalesce(sum(bytes), 0)::bigint
		FROM sync_gateway.media`, owner).Scan(&mine, &total)
	return
}

// Save spools the upload first, so the size is known and enforced before anything
// reaches the blob store. The limit is the smaller of the blob cap and remaining quota.
func (m *MediaStore) Save(ctx context.Context, owner string, r io.Reader) (string, error) {
	select {
	case m.slots <- struct{}{}:
		defer func() { <-m.slots }()
	case <-ctx.Done():
		return "", ctx.Err()
	}
	mine, total, err := m.usage(ctx, owner)
	if err != nil {
		return "", err
	}
	limit := int64(maxMediaBytes)
	if room := m.limits.PerOwner - mine; room < limit {
		limit = room
	}
	if room := m.limits.Total - total; room < limit {
		limit = room
	}
	if limit <= 0 {
		return "", errMediaQuota
	}
	raw := make([]byte, 16)
	if _, err := rand.Read(raw); err != nil {
		return "", err
	}
	id := hex.EncodeToString(raw)
	tmp, err := os.CreateTemp(m.spool, "up-*")
	if err != nil {
		return "", err
	}
	defer os.Remove(tmp.Name())
	defer tmp.Close()
	n, err := io.Copy(tmp, io.LimitReader(r, limit+1))
	if err != nil {
		return "", err
	}
	if n > limit {
		if limit < maxMediaBytes {
			return "", errMediaQuota
		}
		return "", errMediaTooLarge
	}
	if n == 0 {
		return "", errMediaEmpty
	}
	if !m.blobs.HasRoom(n) {
		return "", errMediaQuota
	}
	if _, err := tmp.Seek(0, io.SeekStart); err != nil {
		return "", err
	}
	if err := m.blobs.Put(ctx, id, tmp, n); err != nil {
		return "", err
	}
	if _, err := m.store.db.Exec(ctx, `INSERT INTO sync_gateway.media (id, owner, bytes, created_at) VALUES ($1, $2, $3, $4)`,
		id, owner, n, time.Now().UnixMilli()); err != nil {
		_ = m.blobs.Delete(context.Background(), []string{id})
		return "", err
	}
	return id, nil
}

func (m *MediaStore) CleanupLoop(ctx context.Context) {
	t := time.NewTicker(time.Hour)
	defer t.Stop()
	for {
		if err := m.Cleanup(ctx, time.Now()); err != nil && ctx.Err() == nil {
			log.Printf("media cleanup: %v", err)
		}
		select {
		case <-ctx.Done():
			return
		case <-t.C:
		}
	}
}

// Cleanup removes blobs past their TTL. A row goes only once its blob has gone, so a
// failed delete is retried on the next run rather than leaving an untracked file.
func (m *MediaStore) Cleanup(ctx context.Context, now time.Time) error {
	cutoff := now.Add(-m.limits.TTL).UnixMilli()
	rows, err := m.store.db.Query(ctx, `SELECT id FROM sync_gateway.media WHERE created_at < $1 LIMIT $2`, cutoff, blobDeleteSize)
	if err != nil {
		return err
	}
	ids := []string{}
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			rows.Close()
			return err
		}
		ids = append(ids, id)
	}
	rows.Close()
	if err := rows.Err(); err != nil || len(ids) == 0 {
		return err
	}
	if err := m.blobs.Delete(ctx, ids); err != nil {
		return err
	}
	_, err = m.store.db.Exec(ctx, `DELETE FROM sync_gateway.media WHERE id = ANY($1::text[])`, ids)
	return err
}

// DiskBlobs keeps blobs in a folder, for local development.
type DiskBlobs struct{ dir string }

func NewDiskBlobs(dir string) (*DiskBlobs, error) {
	return &DiskBlobs{dir: dir}, os.MkdirAll(dir, 0o700)
}

func (d *DiskBlobs) Put(_ context.Context, id string, f *os.File, _ int64) error {
	out, err := os.OpenFile(filepath.Join(d.dir, id), os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o600)
	if err != nil {
		return err
	}
	defer out.Close()
	_, err = io.Copy(out, f)
	return err
}

func (d *DiskBlobs) Get(_ context.Context, id string) (io.ReadCloser, int64, error) {
	f, err := os.Open(filepath.Join(d.dir, id))
	if errors.Is(err, os.ErrNotExist) {
		return nil, 0, errBlobNotFound
	}
	if err != nil {
		return nil, 0, err
	}
	st, err := f.Stat()
	if err != nil {
		f.Close()
		return nil, 0, err
	}
	return f, st.Size(), nil
}

func (d *DiskBlobs) Delete(_ context.Context, ids []string) error {
	for _, id := range ids {
		if err := os.Remove(filepath.Join(d.dir, id)); err != nil && !errors.Is(err, os.ErrNotExist) {
			return err
		}
	}
	return nil
}

// HasRoom keeps a floor of free space, so media can never fill the volume.
func (d *DiskBlobs) HasRoom(size int64) bool {
	var st syscall.Statfs_t
	if err := syscall.Statfs(d.dir, &st); err != nil {
		return false
	}
	return int64(st.Bavail)*int64(st.Bsize)-size > minFreeDisk
}

// SupabaseBlobs keeps blobs in a private Supabase Storage bucket. The service role key
// stays on the gateway: clients only ever talk to the gateway, and blobs are ciphertext.
type SupabaseBlobs struct {
	base, key, bucket string
	http              *http.Client
}

func NewSupabaseBlobs(ctx context.Context, base, key, bucket string) (*SupabaseBlobs, error) {
	u, err := url.Parse(base)
	if err != nil || u.Host == "" {
		return nil, errors.New("SUPABASE_URL is not a valid URL")
	}
	s := &SupabaseBlobs{base: strings.TrimRight(base, "/"), key: key, bucket: bucket, http: &http.Client{Timeout: blobHTTPLimit}}
	return s, s.ensureBucket(ctx)
}

func (s *SupabaseBlobs) req(ctx context.Context, method, path string, body io.Reader) (*http.Request, error) {
	r, err := http.NewRequestWithContext(ctx, method, s.base+"/storage/v1/"+path, body)
	if err != nil {
		return nil, err
	}
	r.Header.Set("Authorization", "Bearer "+s.key)
	r.Header.Set("apikey", s.key)
	return r, nil
}

func statusError(what string, resp *http.Response) error {
	msg, _ := io.ReadAll(io.LimitReader(resp.Body, 512))
	return fmt.Errorf("supabase storage %s: %d %s", what, resp.StatusCode, strings.TrimSpace(string(msg)))
}

func (s *SupabaseBlobs) ensureBucket(ctx context.Context) error {
	body, _ := json.Marshal(map[string]any{"id": s.bucket, "name": s.bucket, "public": false})
	r, err := s.req(ctx, http.MethodPost, "bucket", bytes.NewReader(body))
	if err != nil {
		return err
	}
	r.Header.Set("Content-Type", "application/json")
	resp, err := s.http.Do(r)
	if err != nil {
		return fmt.Errorf("supabase storage: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode == http.StatusOK {
		return nil
	}
	// Storage reports an existing bucket as 400 or 409 with "already exists".
	msg, _ := io.ReadAll(io.LimitReader(resp.Body, 512))
	if strings.Contains(strings.ToLower(string(msg)), "already exists") {
		return nil
	}
	return fmt.Errorf("supabase storage bucket: %d %s", resp.StatusCode, strings.TrimSpace(string(msg)))
}

func (s *SupabaseBlobs) Put(ctx context.Context, id string, f *os.File, size int64) error {
	r, err := s.req(ctx, http.MethodPost, "object/"+s.bucket+"/"+id, f)
	if err != nil {
		return err
	}
	r.ContentLength = size
	r.Header.Set("Content-Type", "application/octet-stream")
	r.Header.Set("x-upsert", "false")
	resp, err := s.http.Do(r)
	if err != nil {
		return fmt.Errorf("supabase storage put: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return statusError("put", resp)
	}
	return nil
}

func (s *SupabaseBlobs) Get(ctx context.Context, id string) (io.ReadCloser, int64, error) {
	r, err := s.req(ctx, http.MethodGet, "object/"+s.bucket+"/"+id, nil)
	if err != nil {
		return nil, 0, err
	}
	resp, err := s.http.Do(r)
	if err != nil {
		return nil, 0, fmt.Errorf("supabase storage get: %w", err)
	}
	if resp.StatusCode == http.StatusOK {
		return resp.Body, resp.ContentLength, nil
	}
	defer resp.Body.Close()
	// Storage answers a missing object with 400 or 404, depending on version.
	if resp.StatusCode == http.StatusNotFound || resp.StatusCode == http.StatusBadRequest {
		return nil, 0, errBlobNotFound
	}
	return nil, 0, statusError("get", resp)
}

func (s *SupabaseBlobs) Delete(ctx context.Context, ids []string) error {
	body, _ := json.Marshal(map[string]any{"prefixes": ids})
	r, err := s.req(ctx, http.MethodDelete, "object/"+s.bucket, bytes.NewReader(body))
	if err != nil {
		return err
	}
	r.Header.Set("Content-Type", "application/json")
	resp, err := s.http.Do(r)
	if err != nil {
		return fmt.Errorf("supabase storage delete: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return statusError("delete", resp)
	}
	return nil
}

// HasRoom is always true: MediaLimits.Total is the bound for a remote bucket.
func (s *SupabaseBlobs) HasRoom(int64) bool { return true }
