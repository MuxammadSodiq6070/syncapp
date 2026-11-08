package main

import (
	"context"
	_ "embed"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"
)

//go:embed migrations/0001_init.sql
var migrationSQL string

const (
	dbTimeout = 10 * time.Second

	maxQueueRows    = 20000
	maxQueueBytes   = 256 << 20
	maxShareRows    = maxQueueRows / 4 // one sender can never fill a recipient's queue
	maxShareBytes   = maxQueueBytes / 4
	queueRetention  = 30 * 24 * time.Hour
	searchMinPrefix = 4
	searchLimit     = 10
	maxWatched      = 5000
)

var (
	ErrUsernameTaken = errors.New("username_taken")
	ErrQueueFull     = errors.New("queue_full")
)

// User is the public directory entry. BoxSig lets clients verify BoxPK themselves.
type User struct {
	ID          string `json:"id"`
	BoxPK       string `json:"box_pk"`
	BoxSig      string `json:"box_sig"`
	Username    string `json:"username"`
	DisplayName string `json:"display_name"`
}

// Queued is an envelope waiting for its recipient to acknowledge it.
type Queued struct {
	Seq  int64
	From string
	Blob string
}

type Store struct{ db *pgxpool.Pool }

func OpenStore(ctx context.Context, url string) (*Store, error) {
	cfg, err := pgxpool.ParseConfig(url)
	if err != nil {
		// Not %w: pgx may quote the URL, and that contains the password.
		return nil, errors.New("DATABASE_URL could not be parsed")
	}
	// Works through Supabase's connection pooler as well as a direct connection,
	// because it does not rely on prepared statements surviving between queries.
	cfg.ConnConfig.DefaultQueryExecMode = pgx.QueryExecModeExec
	cfg.MaxConns = 20
	db, err := pgxpool.NewWithConfig(ctx, cfg)
	if err != nil {
		return nil, fmt.Errorf("connect: %w", err)
	}
	s := &Store{db: db}
	if err := s.migrate(ctx); err != nil {
		db.Close()
		return nil, err
	}
	return s, nil
}

func (s *Store) migrate(ctx context.Context) error {
	conn, err := s.db.Acquire(ctx)
	if err != nil {
		return fmt.Errorf("connect: %w", err)
	}
	defer conn.Release()
	const lockID = 7265746 // arbitrary, unique to this app
	if _, err := conn.Exec(ctx, "SELECT pg_advisory_lock($1)", lockID); err != nil {
		return err
	}
	defer conn.Exec(context.Background(), "SELECT pg_advisory_unlock($1)", lockID)
	if _, err := conn.Exec(ctx, migrationSQL); err != nil {
		return fmt.Errorf("migrate: %w", err)
	}
	return nil
}

func (s *Store) Close() { s.db.Close() }

func ctxDB() (context.Context, context.CancelFunc) {
	return context.WithTimeout(context.Background(), dbTimeout)
}

// Identity returns the stored keys of an existing identity, or nil.
func (s *Store) Identity(id string) (*User, error) { return s.User(id) }

// RefreshIdentity updates the keys of an identity that already exists. It never
// creates one: registration goes through Register, which requires verification.
func (s *Store) RefreshIdentity(id, boxPK, boxSig string) (*User, error) {
	ctx, cancel := ctxDB()
	defer cancel()
	u := &User{ID: id, BoxPK: boxPK, BoxSig: boxSig}
	err := s.db.QueryRow(ctx, `
		UPDATE sync_gateway.users SET box_pk = $2, box_sig = $3 WHERE id = $1
		RETURNING username, display_name`, id, boxPK, boxSig).
		Scan(&u.Username, &u.DisplayName)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil
	}
	return u, err
}

// Register creates an identity. phoneHash is empty when verification is switched off;
// otherwise the unique index refuses a number that already has an account.
func (s *Store) Register(id, boxPK, boxSig, phoneHash string) (*User, error) {
	ctx, cancel := ctxDB()
	defer cancel()
	var hash *string
	if phoneHash != "" {
		hash = &phoneHash
	}
	u := &User{ID: id, BoxPK: boxPK, BoxSig: boxSig}
	_, err := s.db.Exec(ctx, `
		INSERT INTO sync_gateway.users (id, box_pk, box_sig, phone_hash) VALUES ($1, $2, $3, $4)`,
		id, boxPK, boxSig, hash)
	var pgErr *pgconn.PgError
	if errors.As(err, &pgErr) && pgErr.Code == "23505" {
		if pgErr.ConstraintName == "users_phone_hash" {
			return nil, errPhoneInUse
		}
		// The identity appeared between the lookup and here; treat it as existing.
		return s.RefreshIdentity(id, boxPK, boxSig)
	}
	return u, err
}

func (s *Store) User(id string) (*User, error) {
	ctx, cancel := ctxDB()
	defer cancel()
	u := &User{ID: id}
	err := s.db.QueryRow(ctx, `SELECT box_pk, box_sig, username, display_name FROM sync_gateway.users WHERE id = $1`, id).
		Scan(&u.BoxPK, &u.BoxSig, &u.Username, &u.DisplayName)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil
	}
	return u, err
}

func (s *Store) SetProfile(id, username, displayName string) error {
	ctx, cancel := ctxDB()
	defer cancel()
	tag, err := s.db.Exec(ctx, `
		UPDATE sync_gateway.users SET username = $2, username_lower = $3, display_name = $4 WHERE id = $1`,
		id, username, strings.ToLower(username), displayName)
	var pgErr *pgconn.PgError
	if errors.As(err, &pgErr) && pgErr.Code == "23505" {
		return ErrUsernameTaken
	}
	if err == nil && tag.RowsAffected() == 0 {
		return errors.New("unknown_user")
	}
	return err
}

func (s *Store) SetLastSeen(id string, ts int64) {
	ctx, cancel := ctxDB()
	defer cancel()
	_, _ = s.db.Exec(ctx, `UPDATE sync_gateway.users SET last_seen = $2 WHERE id = $1`, id, ts)
}

func (s *Store) LastSeen(id string) int64 {
	ctx, cancel := ctxDB()
	defer cancel()
	var ts int64
	_ = s.db.QueryRow(ctx, `SELECT last_seen FROM sync_gateway.users WHERE id = $1`, id).Scan(&ts)
	return ts
}

func escapeLike(q string) string {
	return strings.NewReplacer(`\`, `\\`, `%`, `\%`, `_`, `\_`).Replace(q)
}

// SearchUsers matches an exact id or username, or a username prefix long enough that
// walking the whole directory by prefix is impractical. Results carry no activity data.
func (s *Store) SearchUsers(q string) ([]*User, error) {
	q = strings.ToLower(strings.TrimPrefix(strings.TrimSpace(q), "@"))
	out := []*User{}
	if q == "" {
		return out, nil
	}
	ctx, cancel := ctxDB()
	defer cancel()
	sql := `SELECT id, box_pk, box_sig, username, display_name FROM sync_gateway.users WHERE id = $1 OR username_lower = $1 LIMIT $2`
	args := []any{q, searchLimit}
	if len(q) >= searchMinPrefix {
		sql = `SELECT id, box_pk, box_sig, username, display_name FROM sync_gateway.users
		       WHERE id = $1 OR username_lower LIKE $2 ORDER BY username_lower LIMIT $3`
		args = []any{q, escapeLike(q) + "%", searchLimit}
	}
	rows, err := s.db.Query(ctx, sql, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	for rows.Next() {
		u := &User{}
		if err := rows.Scan(&u.ID, &u.BoxPK, &u.BoxSig, &u.Username, &u.DisplayName); err != nil {
			return nil, err
		}
		out = append(out, u)
	}
	return out, rows.Err()
}

// Enqueue durably stores an envelope, within the recipient's quota and the sender's
// share of it. The conditional upserts make the check and the count one atomic step.
func (s *Store) Enqueue(to, from, blob string) error {
	ctx, cancel := ctxDB()
	defer cancel()
	size := int64(len(blob))
	return pgx.BeginFunc(ctx, s.db, func(tx pgx.Tx) error {
		tag, err := tx.Exec(ctx, `
			INSERT INTO sync_gateway.queue_usage AS u (recipient, rows, bytes) VALUES ($1, 1, $2)
			ON CONFLICT (recipient) DO UPDATE SET rows = u.rows + 1, bytes = u.bytes + $2
			WHERE u.rows < $3 AND u.bytes + $2 <= $4`, to, size, maxQueueRows, int64(maxQueueBytes))
		if err != nil {
			return err
		}
		if tag.RowsAffected() == 0 {
			return ErrQueueFull
		}
		tag, err = tx.Exec(ctx, `
			INSERT INTO sync_gateway.queue_share AS q (recipient, sender, rows, bytes) VALUES ($1, $2, 1, $3)
			ON CONFLICT (recipient, sender) DO UPDATE SET rows = q.rows + 1, bytes = q.bytes + $3
			WHERE q.rows < $4 AND q.bytes + $3 <= $5`, to, from, size, maxShareRows, int64(maxShareBytes))
		if err != nil {
			return err
		}
		if tag.RowsAffected() == 0 {
			return ErrQueueFull
		}
		_, err = tx.Exec(ctx, `
			INSERT INTO sync_gateway.queue (recipient, sender, blob, bytes, created_at) VALUES ($1, $2, $3, $4, $5)`,
			to, from, blob, size, time.Now().UnixMilli())
		return err
	})
}

// Pending returns up to limit queued envelopes with a sequence above after.
func (s *Store) Pending(to string, after int64, limit int) ([]Queued, error) {
	ctx, cancel := ctxDB()
	defer cancel()
	rows, err := s.db.Query(ctx, `
		SELECT seq, sender, blob FROM sync_gateway.queue WHERE recipient = $1 AND seq > $2 ORDER BY seq LIMIT $3`,
		to, after, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []Queued{}
	for rows.Next() {
		var q Queued
		if err := rows.Scan(&q.Seq, &q.From, &q.Blob); err != nil {
			return nil, err
		}
		out = append(out, q)
	}
	return out, rows.Err()
}

func releaseQueue(ctx context.Context, tx pgx.Tx, to, from string, size int64) error {
	if _, err := tx.Exec(ctx, `UPDATE sync_gateway.queue_usage SET rows = rows - 1, bytes = bytes - $2 WHERE recipient = $1`, to, size); err != nil {
		return err
	}
	_, err := tx.Exec(ctx, `UPDATE sync_gateway.queue_share SET rows = rows - 1, bytes = bytes - $3 WHERE recipient = $1 AND sender = $2`, to, from, size)
	return err
}

// Ack deletes a row, only for its own recipient. Repeating it changes nothing.
func (s *Store) Ack(to string, seq int64) error {
	ctx, cancel := ctxDB()
	defer cancel()
	return pgx.BeginFunc(ctx, s.db, func(tx pgx.Tx) error {
		var from string
		var size int64
		err := tx.QueryRow(ctx, `DELETE FROM sync_gateway.queue WHERE recipient = $1 AND seq = $2 RETURNING sender, bytes`, to, seq).Scan(&from, &size)
		if errors.Is(err, pgx.ErrNoRows) {
			return nil
		}
		if err != nil {
			return err
		}
		return releaseQueue(ctx, tx, to, from, size)
	})
}

// SweepQueue drops undelivered envelopes older than the retention period.
func (s *Store) SweepQueue(now time.Time) (int, error) {
	ctx, cancel := context.WithTimeout(context.Background(), time.Minute)
	defer cancel()
	cutoff := now.Add(-queueRetention).UnixMilli()
	total := 0
	err := pgx.BeginFunc(ctx, s.db, func(tx pgx.Tx) error {
		rows, err := tx.Query(ctx, `DELETE FROM sync_gateway.queue WHERE created_at < $1 RETURNING recipient, sender, bytes`, cutoff)
		if err != nil {
			return err
		}
		type row struct {
			to, from string
			size     int64
		}
		var gone []row
		for rows.Next() {
			var r row
			if err := rows.Scan(&r.to, &r.from, &r.size); err != nil {
				rows.Close()
				return err
			}
			gone = append(gone, r)
		}
		rows.Close()
		if err := rows.Err(); err != nil {
			return err
		}
		for _, r := range gone {
			if err := releaseQueue(ctx, tx, r.to, r.from, r.size); err != nil {
				return err
			}
		}
		total = len(gone)
		return nil
	})
	return total, err
}

// Watch records who someone asks about and returns which of them ask back. Presence
// flows only between those two: asking is the consent, so strangers learn nothing.
func (s *Store) Watch(watcher string, ids []string) ([]string, error) {
	ctx, cancel := ctxDB()
	defer cancel()
	mutual := []string{}
	err := pgx.BeginFunc(ctx, s.db, func(tx pgx.Tx) error {
		var have int
		if err := tx.QueryRow(ctx, `SELECT count(*) FROM sync_gateway.watches WHERE watcher = $1`, watcher).Scan(&have); err != nil {
			return err
		}
		if room := maxWatched - have; room < len(ids) {
			if room < 0 {
				room = 0
			}
			ids = ids[:room]
		}
		if _, err := tx.Exec(ctx, `
			INSERT INTO sync_gateway.watches (watcher, target) SELECT $1, unnest($2::text[]) ON CONFLICT DO NOTHING`, watcher, ids); err != nil {
			return err
		}
		rows, err := tx.Query(ctx, `SELECT target FROM sync_gateway.watches WHERE watcher = $1 AND target IN
			(SELECT watcher FROM sync_gateway.watches WHERE target = $1)`, watcher)
		if err != nil {
			return err
		}
		defer rows.Close()
		for rows.Next() {
			var id string
			if err := rows.Scan(&id); err != nil {
				return err
			}
			mutual = append(mutual, id)
		}
		return rows.Err()
	})
	return mutual, err
}

func (s *Store) Unwatch(watcher string, ids []string) error {
	ctx, cancel := ctxDB()
	defer cancel()
	_, err := s.db.Exec(ctx, `DELETE FROM sync_gateway.watches WHERE watcher = $1 AND target = ANY($2::text[])`, watcher, ids)
	return err
}

// marshalFrame writes JSON without HTML escaping, so a frame is never larger on the
// way out than what was accepted and counted on the way in.
func marshalFrame(v any) ([]byte, error) {
	var b strings.Builder
	enc := json.NewEncoder(&b)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(v); err != nil {
		return nil, err
	}
	return []byte(strings.TrimRight(b.String(), "\n")), nil
}
