package main

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"encoding/hex"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/anthropics/anthropic-sdk-go/v2/option"
	"github.com/gorilla/websocket"
)

// Tests use a real Postgres: SYNC_TEST_DATABASE_URL. The schema is emptied per test.

type testClient struct {
	t   *testing.T
	ws  *websocket.Conn
	in  chan map[string]any
	id  string
	pk  ed25519.PublicKey
	sk  ed25519.PrivateKey
	box []byte
}

func testStore(t *testing.T) *Store {
	t.Helper()
	url := os.Getenv("SYNC_TEST_DATABASE_URL")
	if url == "" {
		t.Skip("set SYNC_TEST_DATABASE_URL")
	}
	store, err := OpenStore(context.Background(), url)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(store.Close)
	_, err = store.db.Exec(context.Background(), `TRUNCATE sync_gateway.users, sync_gateway.queue, sync_gateway.queue_usage,
		sync_gateway.queue_share, sync_gateway.watches, sync_gateway.media, sync_gateway.market,
		sync_gateway.signup_codes, sync_gateway.sms_budget, sync_gateway.service_messages,
		sync_gateway.bot_verifications`)
	if err != nil {
		t.Fatal(err)
	}
	return store
}

func newServer(t *testing.T) (*httptest.Server, *Store, *MediaStore, *Hub) {
	t.Helper()
	store := testStore(t)
	dir := t.TempDir()
	blobs, err := NewDiskBlobs(dir + "/media")
	if err != nil {
		t.Fatal(err)
	}
	media, err := NewMediaStore(store, blobs, MediaLimits{PerOwner: 1 << 30, Total: 1 << 40, TTL: time.Hour}, dir+"/spool")
	if err != nil {
		t.Fatal(err)
	}
	hub := NewHub(store, media)
	srv := httptest.NewServer(hub.Routes())
	t.Cleanup(func() {
		hub.CloseAll()
		srv.Close()
	})
	return srv, store, media, hub
}

func newIdentity(t *testing.T) *testClient {
	t.Helper()
	pk, sk, err := ed25519.GenerateKey(nil)
	if err != nil {
		t.Fatal(err)
	}
	return &testClient{t: t, id: hex.EncodeToString(pk), pk: pk, sk: sk, box: bytes.Repeat([]byte{7}, 32)}
}

func (c *testClient) dial(srv *httptest.Server) {
	c.t.Helper()
	ws, _, err := websocket.DefaultDialer.Dial("ws"+strings.TrimPrefix(srv.URL, "http")+"/ws", nil)
	if err != nil {
		c.t.Fatal(err)
	}
	c.t.Cleanup(func() { ws.Close() })
	c.ws = ws
	// A read timeout leaves a gorilla connection unusable, so one goroutine reads
	// and the tests wait on a channel instead.
	in := make(chan map[string]any, 1024)
	c.in = in
	go func() {
		defer close(in)
		for {
			var m map[string]any
			if err := ws.ReadJSON(&m); err != nil {
				return
			}
			in <- m
		}
	}()
}

func (c *testClient) read() map[string]any {
	c.t.Helper()
	select {
	case m, ok := <-c.in:
		if !ok {
			c.t.Fatal("connection closed")
		}
		return m
	case <-time.After(5 * time.Second):
		c.t.Fatal("read timed out")
		return nil
	}
}

func (c *testClient) readType(want string) map[string]any {
	c.t.Helper()
	for {
		if m := c.read(); m["t"] == want {
			return m
		}
	}
}

// silent asserts nothing of type want arrives for a moment.
func (c *testClient) silent(want string, d time.Duration) {
	c.t.Helper()
	deadline := time.After(d)
	for {
		select {
		case m, ok := <-c.in:
			if !ok {
				return
			}
			if m["t"] == want {
				c.t.Fatalf("unexpected %s: %v", want, m)
			}
		case <-deadline:
			return
		}
	}
}

func (c *testClient) login(srv *httptest.Server) {
	c.t.Helper()
	if err := c.tryLogin(srv, ""); err != "" {
		c.t.Fatalf("login refused: %s", err)
	}
}

// tryLoginWithCode registers with a phone number and the code that was sent to it.
func (c *testClient) tryLoginWithCode(srv *httptest.Server, phone, code string) string {
	c.t.Helper()
	return c.authAs(srv, map[string]any{"phone": phone, "code": code})
}

// tryLogin returns "" on success, otherwise the reason the gateway gave.
func (c *testClient) tryLogin(srv *httptest.Server, fbToken string) string {
	c.t.Helper()
	return c.authAs(srv, map[string]any{"fb_token": fbToken})
}

func (c *testClient) authAs(srv *httptest.Server, proof map[string]any) string {
	c.t.Helper()
	c.dial(srv)
	ch := c.readType("challenge")
	nonce, _ := hex.DecodeString(ch["nonce"].(string))
	frame := map[string]any{
		"t": "auth", "id": c.id,
		"box_pk":  hex.EncodeToString(c.box),
		"box_sig": hex.EncodeToString(ed25519.Sign(c.sk, append([]byte("sync-box-binding-v1"), c.box...))),
		"sig":     hex.EncodeToString(ed25519.Sign(c.sk, append([]byte("sync-auth-v1"), nonce...))),
	}
	for k, v := range proof {
		frame[k] = v
	}
	c.ws.WriteJSON(frame)
	for {
		m, ok := <-c.in
		if !ok {
			return "closed"
		}
		switch m["t"] {
		case "ready":
			return ""
		case "auth_error":
			reason, _ := m["reason"].(string)
			return reason
		}
	}
}

func (c *testClient) call(req map[string]any) map[string]any {
	c.t.Helper()
	req["rid"] = "r"
	c.ws.WriteJSON(req)
	return c.readType("res")
}

func TestAuthRejectsBadSignature(t *testing.T) {
	srv, _, _, _ := newServer(t)
	c := newIdentity(t)
	c.dial(srv)
	c.readType("challenge")
	other := newIdentity(t)
	c.ws.WriteJSON(map[string]any{
		"t": "auth", "id": c.id,
		"box_pk":  hex.EncodeToString(c.box),
		"box_sig": hex.EncodeToString(ed25519.Sign(c.sk, append([]byte("sync-box-binding-v1"), c.box...))),
		"sig":     hex.EncodeToString(ed25519.Sign(other.sk, []byte("anything"))),
	})
	if _, ok := <-c.in; ok {
		t.Fatal("expected the gateway to close the connection")
	}
}

func TestPreAuthFramesAreSmall(t *testing.T) {
	srv, _, _, _ := newServer(t)
	c := newIdentity(t)
	c.dial(srv)
	c.readType("challenge")
	c.ws.WriteMessage(websocket.TextMessage, bytes.Repeat([]byte("x"), preAuthFrame+1))
	select {
	case _, ok := <-c.in:
		if ok {
			t.Fatal("oversized pre-auth frame was accepted")
		}
	case <-time.After(5 * time.Second):
		t.Fatal("the connection stayed open")
	}
}

func TestOfflineQueueAndRedelivery(t *testing.T) {
	srv, _, _, _ := newServer(t)
	a, b := newIdentity(t), newIdentity(t)
	a.login(srv)
	b.login(srv)
	b.ws.Close()
	time.Sleep(50 * time.Millisecond)

	if r := a.call(map[string]any{"t": "send", "to": b.id, "blob": "QQ=="}); r["ok"] != true {
		t.Fatalf("send: %v", r)
	}

	b.login(srv)
	m := b.readType("msg")
	if m["from"] != a.id || m["blob"] != "QQ==" {
		t.Fatalf("bad message: %v", m)
	}
	seq := m["seq"]

	// Not acked, so a reconnect must redeliver it.
	b.ws.Close()
	time.Sleep(50 * time.Millisecond)
	b.login(srv)
	m = b.readType("msg")
	if m["seq"] != seq {
		t.Fatalf("expected redelivery of %v, got %v", seq, m)
	}

	// Someone else's ack does nothing; the recipient's own removes it.
	a.ws.WriteJSON(map[string]any{"t": "ack", "seq": seq})
	time.Sleep(50 * time.Millisecond)
	b.ws.Close()
	time.Sleep(50 * time.Millisecond)
	b.login(srv)
	b.readType("msg")
	b.ws.WriteJSON(map[string]any{"t": "ack", "seq": seq})
	time.Sleep(100 * time.Millisecond)
	b.ws.Close()
	time.Sleep(50 * time.Millisecond)
	b.login(srv)
	b.silent("msg", 300*time.Millisecond)
}

func TestSendOrderUnknownUserAndBlobShape(t *testing.T) {
	srv, _, _, _ := newServer(t)
	a, b := newIdentity(t), newIdentity(t)
	a.login(srv)
	b.login(srv)
	if r := a.call(map[string]any{"t": "send", "to": strings.Repeat("a", 64), "blob": "QQ=="}); r["error"] != "unknown_user" {
		t.Fatalf("got %v", r)
	}
	for _, bad := range []string{"", "<<<<", "QQ=", "Q=QQ"} {
		if r := a.call(map[string]any{"t": "send", "to": b.id, "blob": bad}); r["error"] != "bad_request" {
			t.Fatalf("blob %q: %v", bad, r)
		}
	}
	for _, blob := range []string{"AQ==", "Ag==", "Aw=="} {
		if r := a.call(map[string]any{"t": "send", "to": b.id, "blob": blob}); r["ok"] != true {
			t.Fatalf("send: %v", r)
		}
	}
	for _, want := range []string{"AQ==", "Ag==", "Aw=="} {
		if m := b.readType("msg"); m["blob"] != want {
			t.Fatalf("out of order: want %s got %v", want, m["blob"])
		}
	}
}

// One sender cannot use up a recipient's queue, by rows or by bytes.
func TestQueueQuotas(t *testing.T) {
	store := testStore(t)
	ctx := context.Background()
	to, stranger, friend := strings.Repeat("a", 64), strings.Repeat("b", 64), strings.Repeat("c", 64)
	if err := store.Enqueue(to, stranger, "QQ=="); err != nil {
		t.Fatal(err)
	}
	if _, err := store.db.Exec(ctx, `UPDATE sync_gateway.queue_share SET rows = $1`, maxShareRows); err != nil {
		t.Fatal(err)
	}
	if err := store.Enqueue(to, stranger, "QQ=="); err != ErrQueueFull {
		t.Fatalf("share by rows: %v", err)
	}
	if err := store.Enqueue(to, friend, "QQ=="); err != nil {
		t.Fatalf("another sender was blocked: %v", err)
	}
	if _, err := store.db.Exec(ctx, `UPDATE sync_gateway.queue_share SET rows = 1, bytes = $1 WHERE sender = $2`, int64(maxShareBytes), stranger); err != nil {
		t.Fatal(err)
	}
	if err := store.Enqueue(to, stranger, "QQ=="); err != ErrQueueFull {
		t.Fatalf("share by bytes: %v", err)
	}
	if _, err := store.db.Exec(ctx, `UPDATE sync_gateway.queue_usage SET bytes = $1`, int64(maxQueueBytes)); err != nil {
		t.Fatal(err)
	}
	if err := store.Enqueue(to, friend, "QQ=="); err != ErrQueueFull {
		t.Fatalf("total bytes: %v", err)
	}
	// A failed enqueue changed nothing.
	var rows int
	if err := store.db.QueryRow(ctx, `SELECT count(*) FROM sync_gateway.queue`).Scan(&rows); err != nil || rows != 2 {
		t.Fatalf("rows %d %v", rows, err)
	}

	// Acks and expiry give the room back, and duplicates do not over-credit.
	if _, err := store.db.Exec(ctx, `UPDATE sync_gateway.queue_usage SET rows = 2, bytes = 8`); err != nil {
		t.Fatal(err)
	}
	pending, err := store.Pending(to, 0, 10)
	if err != nil || len(pending) != 2 {
		t.Fatalf("%v %v", pending, err)
	}
	store.Ack(to, pending[0].Seq)
	store.Ack(to, pending[0].Seq)
	var usedRows int
	var usedBytes int64
	store.db.QueryRow(ctx, `SELECT rows, bytes FROM sync_gateway.queue_usage`).Scan(&usedRows, &usedBytes)
	if usedRows != 1 || usedBytes != 4 {
		t.Fatalf("after ack: %d %d", usedRows, usedBytes)
	}
	if n, err := store.SweepQueue(time.Now().Add(queueRetention - time.Hour)); err != nil || n != 0 {
		t.Fatalf("swept too early: %d %v", n, err)
	}
	if n, err := store.SweepQueue(time.Now().Add(queueRetention + time.Hour)); err != nil || n != 1 {
		t.Fatalf("sweep: %d %v", n, err)
	}
	store.db.QueryRow(ctx, `SELECT rows, bytes FROM sync_gateway.queue_usage`).Scan(&usedRows, &usedBytes)
	if usedRows != 0 || usedBytes != 0 {
		t.Fatalf("after sweep: %d %d", usedRows, usedBytes)
	}
}

func TestRateLimitSurvivesReconnect(t *testing.T) {
	srv, _, _, _ := newServer(t)
	a := newIdentity(t)
	a.login(srv)
	limited := 0
	for i := 0; i < 2000 && limited == 0; i++ {
		a.ws.WriteJSON(map[string]any{"t": "user", "id": a.id, "rid": "r"})
		if i%50 == 49 {
			for j := 0; j < 50; j++ {
				if m := a.readType("res"); m["error"] == "rate_limited" {
					limited++
				}
			}
		}
	}
	if limited == 0 {
		t.Fatal("never rate limited")
	}
	a.ws.Close()
	time.Sleep(50 * time.Millisecond)
	a.login(srv)
	over := 0
	for i := 0; i < 100; i++ {
		if r := a.call(map[string]any{"t": "user", "id": a.id}); r["error"] == "rate_limited" {
			over++
		}
	}
	if over == 0 {
		t.Fatal("reconnecting refilled the budget")
	}
	// Large frames cost more.
	var l limiter
	l.buckets = map[string]*bucket{}
	now := time.Now()
	if !l.allow("x", rateBurst, now) || l.allow("x", 1, now) {
		t.Fatal("budget not spent by a costly frame")
	}
}

// A stranger's flood reaches a slow client as dropped frames, never a disconnect,
// while the client's own traffic may still use the whole buffer.
func TestTransientCannotDisconnectSomeone(t *testing.T) {
	_, cancel := context.WithCancel(context.Background())
	victim := &Conn{out: make(chan []byte, sendBuffer), done: make(chan struct{}), cancel: cancel}
	big := map[string]any{"t": "transient", "blob": strings.Repeat("A", maxTransient)}
	for i := 0; i < sendBuffer*4; i++ {
		victim.sendBestEffort(big)
	}
	if n := len(victim.out); n > transientRoom+1 {
		t.Fatalf("transient used %d of the %d-frame buffer", n, sendBuffer)
	}
	select {
	case <-victim.done:
		t.Fatal("the victim was disconnected by someone else's traffic")
	default:
	}
	// Only its own replies can cut it off.
	for i := 0; i < sendBuffer*2; i++ {
		victim.sendJSON(map[string]any{"t": "res"})
	}
	select {
	case <-victim.done:
	default:
		t.Fatal("a client that cannot keep up with its own replies stayed connected")
	}
}

// Oversized transient frames are refused outright.
func TestTransientSizeLimit(t *testing.T) {
	srv, _, _, _ := newServer(t)
	a, b := newIdentity(t), newIdentity(t)
	a.login(srv)
	b.login(srv)
	if r := a.call(map[string]any{"t": "send", "to": b.id, "transient": true, "blob": strings.Repeat("A", maxTransient+4)}); r["error"] != "bad_request" {
		t.Fatalf("oversized transient: %v", r)
	}
	if r := a.call(map[string]any{"t": "send", "to": b.id, "transient": true, "blob": "QQ=="}); r["ok"] != true {
		t.Fatalf("normal transient: %v", r)
	}
	if m := b.readType("transient"); m["from"] != a.id {
		t.Fatalf("got %v", m)
	}
}

func TestProfileAndSearch(t *testing.T) {
	srv, store, _, _ := newServer(t)
	a, b := newIdentity(t), newIdentity(t)
	a.login(srv)
	b.login(srv)
	if r := a.call(map[string]any{"t": "profile", "username": "no spaces", "display_name": "A"}); r["ok"] == true {
		t.Fatal("accepted an invalid username")
	}
	if r := a.call(map[string]any{"t": "profile", "username": "Alice_1", "display_name": "Alice"}); r["ok"] != true {
		t.Fatalf("profile: %v", r)
	}
	if r := b.call(map[string]any{"t": "profile", "username": "alice_1", "display_name": "B"}); r["error"] != "username_taken" {
		t.Fatalf("expected case-insensitive conflict: %v", r)
	}
	found := func(q string) int { return len(b.call(map[string]any{"t": "search", "q": q})["users"].([]any)) }
	if found("@ALIC") != 1 || found("alice_1") != 1 {
		t.Fatal("search did not find the user")
	}
	// A short prefix cannot be used to walk the directory.
	for _, q := range []string{"a", "al", "ali"} {
		if found(q) != 0 {
			t.Fatalf("short prefix %q returned users", q)
		}
	}
	// LIKE wildcards are plain characters.
	if found("%%%%") != 0 || found("____") != 0 {
		t.Fatal("wildcards matched")
	}
	// Exact short usernames still work.
	a2 := newIdentity(t)
	a2.login(srv)
	a2.call(map[string]any{"t": "profile", "username": "bob", "display_name": "Bob"})
	if found("bob") != 1 {
		t.Fatal("exact short username not found")
	}
	r := b.call(map[string]any{"t": "search", "q": "alice_1"})
	if _, leaked := r["users"].([]any)[0].(map[string]any)["last_seen"]; leaked {
		t.Fatal("search exposes activity")
	}
	// Renaming frees the old username.
	a.call(map[string]any{"t": "profile", "username": "alice_2", "display_name": "Alice"})
	if r := b.call(map[string]any{"t": "profile", "username": "alice_1", "display_name": "B"}); r["ok"] != true {
		t.Fatalf("old username not freed: %v", r)
	}
	_ = store
}

// Presence needs both people to ask. Strangers get nothing at all.
func TestPresenceIsMutual(t *testing.T) {
	srv, _, _, _ := newServer(t)
	a, b, stranger := newIdentity(t), newIdentity(t), newIdentity(t)
	a.login(srv)
	b.login(srv)
	stranger.login(srv)
	stranger.ws.WriteJSON(map[string]any{"t": "watch", "ids": []string{b.id}})
	stranger.silent("presence", 200*time.Millisecond)

	a.ws.WriteJSON(map[string]any{"t": "watch", "ids": []string{b.id}})
	a.silent("presence", 200*time.Millisecond)
	b.ws.WriteJSON(map[string]any{"t": "watch", "ids": []string{a.id}})
	if m := b.readType("presence"); m["id"] != a.id || m["online"] != true {
		t.Fatalf("b got %v", m)
	}
	if m := a.readType("presence"); m["id"] != b.id || m["online"] != true {
		t.Fatalf("a got %v", m)
	}

	b.ws.Close()
	if m := a.readType("presence"); m["online"] != false || m["last_seen"].(float64) == 0 {
		t.Fatalf("got %v", m)
	}
	stranger.silent("presence", 200*time.Millisecond)

	// Offline but mutual: a fresh watch gets last_seen.
	a.ws.WriteJSON(map[string]any{"t": "watch", "ids": []string{b.id}})
	if m := a.readType("presence"); m["online"] != false || m["last_seen"].(float64) == 0 {
		t.Fatalf("got %v", m)
	}

	// Blocking withdraws it, in both directions.
	b.login(srv)
	a.readType("presence")
	b.ws.WriteJSON(map[string]any{"t": "watch", "ids": []string{a.id}})
	b.readType("presence")
	b.ws.WriteJSON(map[string]any{"t": "unwatch", "ids": []string{a.id}})
	time.Sleep(100 * time.Millisecond)
	a.ws.Close()
	b.silent("presence", 200*time.Millisecond)
	a.login(srv)
	a.ws.WriteJSON(map[string]any{"t": "watch", "ids": []string{b.id}})
	a.silent("presence", 200*time.Millisecond)
}

func uploadTo(t *testing.T, srv *httptest.Server, token string, r io.Reader) *http.Response {
	t.Helper()
	req, _ := http.NewRequest("POST", srv.URL+"/media", r)
	req.Header.Set("Authorization", "Bearer "+token)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	return resp
}

func TestMedia(t *testing.T) {
	srv, _, media, _ := newServer(t)
	body := bytes.Repeat([]byte("z"), 1000)
	owner := strings.Repeat("a", 64)

	if r := uploadTo(t, srv, "nope", bytes.NewReader(body)); r.StatusCode != 401 {
		t.Fatalf("no auth: %d", r.StatusCode)
	}
	forged := owner + ".99999999999.deadbeef"
	if r := uploadTo(t, srv, forged, bytes.NewReader(body)); r.StatusCode != 401 {
		t.Fatalf("forged token: %d", r.StatusCode)
	}
	resp := uploadTo(t, srv, media.Token(owner), bytes.NewReader(body))
	if resp.StatusCode != 200 {
		t.Fatalf("upload: %d", resp.StatusCode)
	}
	var out map[string]string
	json.NewDecoder(resp.Body).Decode(&out)

	get, err := http.Get(srv.URL + "/media/" + out["id"])
	if err != nil {
		t.Fatal(err)
	}
	got, _ := io.ReadAll(get.Body)
	if !bytes.Equal(got, body) || get.Header.Get("X-Content-Type-Options") != "nosniff" {
		t.Fatal("media round trip mismatch")
	}
	for _, bad := range []string{"..%2f..%2fgateway.db", "abc", strings.Repeat("0", 32)} {
		r, err := http.Get(srv.URL + "/media/" + bad)
		if err != nil {
			t.Fatal(err)
		}
		if r.StatusCode != 404 {
			t.Fatalf("%s: %d", bad, r.StatusCode)
		}
	}

	ctx := context.Background()
	if err := media.Cleanup(ctx, time.Now()); err != nil {
		t.Fatal(err)
	}
	if r, _ := http.Get(srv.URL + "/media/" + out["id"]); r.StatusCode != 200 {
		t.Fatal("removed before its TTL")
	}
	if err := media.Cleanup(ctx, time.Now().Add(2*time.Hour)); err != nil {
		t.Fatal(err)
	}
	if r, _ := http.Get(srv.URL + "/media/" + out["id"]); r.StatusCode != 404 {
		t.Fatal("expired media was not removed")
	}
	var rows int
	media.store.db.QueryRow(ctx, `SELECT count(*) FROM sync_gateway.media`).Scan(&rows)
	if rows != 0 {
		t.Fatal("expired media left a row")
	}
}

func TestMediaQuotas(t *testing.T) {
	srv, store, media, _ := newServer(t)
	a, b := strings.Repeat("a", 64), strings.Repeat("b", 64)
	media.limits.PerOwner = 1000
	media.limits.Total = 1500
	put := func(owner string, n int) int {
		r := uploadTo(t, srv, media.Token(owner), bytes.NewReader(make([]byte, n)))
		return r.StatusCode
	}
	if s := put(a, 1001); s != 413 {
		t.Fatalf("over the owner quota in one upload: %d", s)
	}
	if s := put(a, 900); s != 200 {
		t.Fatalf("within quota: %d", s)
	}
	if s := put(a, 200); s != 413 {
		t.Fatalf("over the owner quota: %d", s)
	}
	if s := put(b, 601); s != 413 {
		t.Fatalf("over the total: %d", s)
	}
	if s := put(b, 600); s != 200 {
		t.Fatalf("within the total: %d", s)
	}
	if s := put(b, 1); s != 413 {
		t.Fatalf("total is full: %d", s)
	}
	// A refused upload leaves nothing behind.
	var rows int
	store.db.QueryRow(context.Background(), `SELECT count(*) FROM sync_gateway.media`).Scan(&rows)
	if rows != 2 {
		t.Fatalf("rows %d", rows)
	}
}

func TestSupabaseBlobs(t *testing.T) {
	objects := map[string][]byte{}
	var sawAuth atomic.Bool
	api := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") == "Bearer service-key" && r.Header.Get("apikey") == "service-key" {
			sawAuth.Store(true)
		} else {
			w.WriteHeader(401)
			return
		}
		switch {
		case r.Method == "POST" && r.URL.Path == "/storage/v1/bucket":
			var b map[string]any
			json.NewDecoder(r.Body).Decode(&b)
			if b["public"] != false || b["name"] != "sync-media" {
				t.Errorf("bucket request: %v", b)
			}
			w.WriteHeader(400)
			w.Write([]byte(`{"error":"Duplicate","message":"The resource already exists"}`))
		case r.Method == "POST":
			objects[r.URL.Path], _ = io.ReadAll(r.Body)
		case r.Method == "GET":
			data, ok := objects[r.URL.Path]
			if !ok {
				w.WriteHeader(400)
				return
			}
			w.Write(data)
		case r.Method == "DELETE":
			var b struct {
				Prefixes []string `json:"prefixes"`
			}
			json.NewDecoder(r.Body).Decode(&b)
			for _, id := range b.Prefixes {
				delete(objects, "/storage/v1/object/sync-media/"+id)
			}
		}
	}))
	defer api.Close()
	ctx := context.Background()
	s, err := NewSupabaseBlobs(ctx, api.URL, "service-key", "sync-media")
	if err != nil {
		t.Fatal(err)
	}
	f, _ := os.CreateTemp(t.TempDir(), "x")
	f.WriteString("cipher")
	f.Seek(0, io.SeekStart)
	id := strings.Repeat("1", 32)
	if err := s.Put(ctx, id, f, 6); err != nil {
		t.Fatal(err)
	}
	rc, _, err := s.Get(ctx, id)
	if err != nil {
		t.Fatal(err)
	}
	got, _ := io.ReadAll(rc)
	rc.Close()
	if string(got) != "cipher" {
		t.Fatalf("got %q", got)
	}
	if err := s.Delete(ctx, []string{id}); err != nil {
		t.Fatal(err)
	}
	if _, _, err := s.Get(ctx, id); err != errBlobNotFound {
		t.Fatalf("after delete: %v", err)
	}
	if !sawAuth.Load() {
		t.Fatal("no authenticated request")
	}
	// A rejected key is reported, not swallowed.
	if _, err := NewSupabaseBlobs(ctx, api.URL, "wrong", "sync-media"); err == nil {
		t.Fatal("bad key was accepted")
	}
}

func TestMarketplace(t *testing.T) {
	srv, store, _, _ := newServer(t)
	a, b := newIdentity(t), newIdentity(t)
	a.login(srv)
	b.login(srv)
	a.call(map[string]any{"t": "profile", "username": "seller", "display_name": "Seller"})
	if r := a.call(map[string]any{"t": "market_post", "title": " ", "price": "1"}); r["ok"] == true {
		t.Fatal("accepted an empty title")
	}
	r := a.call(map[string]any{"t": "market_post", "title": "Velosiped", "price": "100$", "description": "yangi"})
	if r["ok"] != true {
		t.Fatalf("post: %v", r)
	}
	id := r["item"].(map[string]any)["id"].(string)
	if r := b.call(map[string]any{"t": "market_list", "q": "VELO"}); len(r["items"].([]any)) != 1 {
		t.Fatalf("list: %v", r)
	}
	if r := b.call(map[string]any{"t": "market_list", "q": "mashina"}); len(r["items"].([]any)) != 0 {
		t.Fatalf("list: %v", r)
	}
	if r := b.call(map[string]any{"t": "market_list", "q": "%"}); len(r["items"].([]any)) != 0 {
		t.Fatalf("wildcard matched: %v", r)
	}
	if r := b.call(map[string]any{"t": "market_delete", "id": id}); r["ok"] == true {
		t.Fatal("another user deleted the listing")
	}
	if r := a.call(map[string]any{"t": "market_delete", "id": id}); r["ok"] != true {
		t.Fatalf("delete: %v", r)
	}

	// Caps, per seller and in total.
	seller := strings.Repeat("c", 64)
	for i := 0; i < maxSellerListing; i++ {
		if err := store.PostListing(&Listing{Seller: seller, Title: "x", Price: "1"}); err != nil {
			t.Fatal(err)
		}
	}
	if err := store.PostListing(&Listing{Seller: seller, Title: "x", Price: "1"}); err != errTooManyListing {
		t.Fatalf("seller cap: %v", err)
	}
	ctx := context.Background()
	if _, err := store.db.Exec(ctx, `INSERT INTO sync_gateway.market (id, seller, seller_name, title, price, description, category, created_at)
		SELECT 'seed'||g, 's'||g, '', 't', 'p', '', '', 1 FROM generate_series(1, $1::int) g`, maxListingsTotal); err != nil {
		t.Fatal(err)
	}
	if err := store.PostListing(&Listing{Seller: strings.Repeat("d", 64), Title: "x", Price: "1"}); err != errMarketFull {
		t.Fatalf("total cap: %v", err)
	}
	// Expired ones are hidden, then swept, which frees the total.
	if err := store.SweepListings(ctx, time.Now()); err != nil {
		t.Fatal(err)
	}
	if err := store.PostListing(&Listing{Seller: strings.Repeat("d", 64), Title: "x", Price: "1"}); err != nil {
		t.Fatalf("after sweep: %v", err)
	}
}

// Nothing reaches these tables through Supabase's public APIs, even if the schema is
// exposed later: every table has RLS on and no policy grants anything.
func TestEveryTableHasRLS(t *testing.T) {
	store := testStore(t)
	rows, err := store.db.Query(context.Background(), `
		SELECT c.relname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
		WHERE n.nspname = 'sync_gateway' AND c.relkind = 'r' AND NOT c.relrowsecurity`)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	for rows.Next() {
		var name string
		rows.Scan(&name)
		t.Errorf("table %s has no row level security", name)
	}
	var policies int
	store.db.QueryRow(context.Background(), `SELECT count(*) FROM pg_policies WHERE schemaname = 'sync_gateway'`).Scan(&policies)
	if policies != 0 {
		t.Errorf("%d policies grant access", policies)
	}
}

func TestAINotConfigured(t *testing.T) {
	t.Setenv("ANTHROPIC_API_KEY", "")
	srv, _, _, _ := newServer(t)
	a := newIdentity(t)
	a.login(srv)
	r := a.call(map[string]any{"t": "ai", "turns": []map[string]string{{"role": "user", "text": "hi"}}})
	if r["error"] != "ai_not_configured" {
		t.Fatalf("got %v", r)
	}
}

func TestAIRequestShapeAndValidation(t *testing.T) {
	var got map[string]any
	var beta string
	api := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		beta = r.Header.Get("anthropic-beta")
		json.NewDecoder(r.Body).Decode(&got)
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte(`{"id":"m","type":"message","role":"assistant","model":"x","content":[{"type":"text","text":"salom"}],"stop_reason":"end_turn","usage":{"input_tokens":1,"output_tokens":1}}`))
	}))
	defer api.Close()
	t.Setenv("ANTHROPIC_API_KEY", "test")
	ai := NewAIService(option.WithBaseURL(api.URL), option.WithMaxRetries(0))
	text, err := ai.Reply(context.Background(), "Pirate", []AITurn{{"user", "hi"}, {"assistant", "yo"}, {"user", "again"}})
	if err != nil || text != "salom" {
		t.Fatalf("reply: %q %v", text, err)
	}
	if got["model"] != "claude-opus-5-5" || !strings.Contains(beta, "server-side-fallback") {
		t.Fatalf("request: %v beta=%q", got["model"], beta)
	}
	if len(got["messages"].([]any)) != 3 {
		t.Fatalf("messages: %v", got["messages"])
	}
	if validateTurns([]AITurn{{"assistant", "x"}}, "") || validateTurns(nil, "") ||
		validateTurns([]AITurn{{"user", "a"}, {"assistant", "b"}}, "") {
		t.Fatal("accepted a malformed conversation")
	}
}

// Many free keys together stay inside the service-wide budget.
func TestAIBudgets(t *testing.T) {
	t.Setenv("ANTHROPIC_API_KEY", "test")
	t.Setenv("SYNC_AI_MAX_PER_MINUTE", "5")
	t.Setenv("SYNC_AI_MAX_PER_DAY", "8")
	ai := NewAIService()
	now := time.Now()
	for i := 0; i < 5; i++ {
		user := strings.Repeat("a", i+1)
		if err := ai.allow(user, now); err != nil {
			t.Fatalf("call %d: %v", i, err)
		}
		ai.finished(user)
	}
	if err := ai.allow("fresh-key", now); err == nil || err.Error() != "ai_busy" {
		t.Fatalf("a fresh key passed the minute budget: %v", err)
	}
	later := now.Add(2 * time.Minute)
	for i := 0; i < 3; i++ {
		if err := ai.allow("u"+strings.Repeat("x", i), later); err != nil {
			t.Fatalf("after a minute: %v", err)
		}
	}
	if err := ai.allow("another", later.Add(2*time.Minute)); err == nil {
		t.Fatal("the daily budget did not apply")
	}
	if err := ai.allow("another", later.Add(25*time.Hour)); err != nil {
		t.Fatalf("the daily budget did not reset: %v", err)
	}

	// One identity cannot hold more than its share of slots.
	t.Setenv("SYNC_AI_MAX_PER_MINUTE", "100")
	t.Setenv("SYNC_AI_MAX_PER_DAY", "100")
	ai = NewAIService()
	for i := 0; i < aiPerUserActive; i++ {
		if err := ai.allow("u", now); err != nil {
			t.Fatal(err)
		}
	}
	if err := ai.allow("u", now); err == nil || err.Error() != "rate_limited" {
		t.Fatalf("got %v", err)
	}
	ai.finished("u")
	if err := ai.allow("u", now); err != nil {
		t.Fatalf("slot not freed: %v", err)
	}
	// Per-user minute limit.
	for i := 0; i < aiPerUserMinute+1; i++ {
		ai.allow("v", now)
		ai.finished("v")
	}
	if err := ai.allow("v", now); err == nil {
		t.Fatal("per-user limit did not apply")
	}
}

// Closing the connection stops the paid call.
func TestAICancelledWhenClientLeaves(t *testing.T) {
	store := testStore(t)
	cancelled := make(chan struct{})
	started := make(chan struct{})
	stop := make(chan struct{})
	api := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// Go only notices the caller leaving once the request body has been read.
		io.Copy(io.Discard, r.Body)
		close(started)
		select {
		case <-r.Context().Done():
			close(cancelled)
		case <-stop:
		}
	}))
	// LIFO: stop releases the handler first, so the server can then shut down.
	defer api.Close()
	defer close(stop)
	t.Setenv("ANTHROPIC_API_KEY", "test")
	dir := t.TempDir()
	blobs, _ := NewDiskBlobs(dir + "/m")
	media, _ := NewMediaStore(store, blobs, MediaLimits{PerOwner: 1, Total: 1, TTL: time.Hour}, dir+"/s")
	hub := NewHub(store, media)
	hub.ai = NewAIService(option.WithBaseURL(api.URL), option.WithMaxRetries(0))
	srv := httptest.NewServer(hub.Routes())
	defer srv.Close()
	a := newIdentity(t)
	a.login(srv)
	a.ws.WriteJSON(map[string]any{"t": "ai", "rid": "r", "turns": []map[string]string{{"role": "user", "text": "hi"}}})
	<-started
	a.ws.Close()
	select {
	case <-cancelled:
	case <-time.After(5 * time.Second):
		t.Fatal("the upstream call kept running")
	}
	hub.CloseAll()
}

func TestIPLimits(t *testing.T) {
	l := ipLimits{conns: map[string]int{}, newIDs: map[string][]time.Time{}}
	for i := 0; i < maxConnsPerIP; i++ {
		if !l.acquire("1.1.1.1") {
			t.Fatal("limited early")
		}
	}
	if l.acquire("1.1.1.1") {
		t.Fatal("connection cap did not apply")
	}
	if !l.acquire("2.2.2.2") {
		t.Fatal("another address was limited")
	}
	l.release("1.1.1.1")
	if !l.acquire("1.1.1.1") {
		t.Fatal("release did not free a slot")
	}
	now := time.Now()
	for i := 0; i < maxNewIDsPerIP; i++ {
		if !l.noteNewID("3.3.3.3", now) {
			t.Fatal("limited early")
		}
	}
	if l.noteNewID("3.3.3.3", now) {
		t.Fatal("new identity cap did not apply")
	}
	if !l.noteNewID("3.3.3.3", now.Add(newIDWindow+time.Second)) {
		t.Fatal("window did not reset")
	}

	// A forged header only counts when a proxy is configured to set it.
	h := &Hub{}
	r := httptest.NewRequest("GET", "/", nil)
	r.RemoteAddr = "9.9.9.9:1234"
	r.Header.Set("X-Forwarded-For", "6.6.6.6, 7.7.7.7")
	if ip := h.clientIP(r); ip != "9.9.9.9" {
		t.Fatalf("forged header trusted: %s", ip)
	}
	h.IPHeader = "X-Forwarded-For"
	if ip := h.clientIP(r); ip != "7.7.7.7" {
		t.Fatalf("got %s", ip)
	}
}

// The app stores need a public privacy-policy URL that keeps working.
func TestPrivacyPolicyIsServed(t *testing.T) {
	srv, _, _, _ := newServer(t)
	resp, err := http.Get(srv.URL + "/privacy")
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	if resp.StatusCode != 200 || !strings.Contains(resp.Header.Get("Content-Type"), "text/html") {
		t.Fatalf("status %d type %q", resp.StatusCode, resp.Header.Get("Content-Type"))
	}
	if !bytes.Contains(body, []byte("Privacy Policy")) {
		t.Fatal("the served page is not the policy")
	}
}

// With verification on, a new account needs a real token and a number nobody has used.
// Coming back never needs one, so restoring from a recovery key costs no SMS.
func TestSignUpRequiresVerifiedPhone(t *testing.T) {
	store := testStore(t)
	g := newFakeGoogle(t)
	dir := t.TempDir()
	blobs, _ := NewDiskBlobs(dir + "/m")
	media, _ := NewMediaStore(store, blobs, MediaLimits{PerOwner: 1 << 20, Total: 1 << 20, TTL: time.Hour}, dir+"/s")
	hub := NewHub(store, media)
	hub.verifier = g.verifier(t)
	srv := httptest.NewServer(hub.Routes())
	defer func() {
		hub.CloseAll()
		srv.Close()
	}()

	a := newIdentity(t)
	if r := a.tryLogin(srv, ""); r != "verification_required" {
		t.Fatalf("signed up with no token: %q", r)
	}
	if r := a.tryLogin(srv, "forged.token.here"); r != "verification_failed" {
		t.Fatalf("forged token: %q", r)
	}
	if r := a.tryLogin(srv, g.token(t)); r != "" {
		t.Fatalf("genuine token refused: %q", r)
	}

	// The same number cannot open a second account.
	b := newIdentity(t)
	if r := b.tryLogin(srv, g.token(t)); r != "phone_already_used" {
		t.Fatalf("one number opened two accounts: %q", r)
	}
	// A different number can.
	other := g.token(t, func(c map[string]any) { c["phone_number"] = "+998900000001" })
	if r := b.tryLogin(srv, other); r != "" {
		t.Fatalf("second number refused: %q", r)
	}

	// Reconnecting needs nothing: this is the recovery-key path.
	a2 := &testClient{t: t, id: a.id, pk: a.pk, sk: a.sk, box: a.box}
	if r := a2.tryLogin(srv, ""); r != "" {
		t.Fatalf("an existing account was asked to verify again: %q", r)
	}

	// The number is never stored, only a keyed hash of it.
	var stored *string
	if err := store.db.QueryRow(context.Background(),
		`SELECT phone_hash FROM sync_gateway.users WHERE id = $1`, a.id).Scan(&stored); err != nil {
		t.Fatal(err)
	}
	if stored == nil || *stored == hub.verifier.PhoneHash("+998901234567") == false {
		t.Fatal("the phone hash was not recorded")
	}
	var leaked int
	store.db.QueryRow(context.Background(),
		`SELECT count(*) FROM sync_gateway.users WHERE phone_hash LIKE '%998%'`).Scan(&leaked)
	if leaked != 0 {
		t.Fatal("the number is recoverable from the stored hash")
	}
}

// Without a project id configured, sign-up stays open, which is how the other tests
// and local development run.
func TestSignUpOpenWhenVerificationOff(t *testing.T) {
	srv, _, _, hub := newServer(t)
	if hub.verifier != nil {
		t.Fatal("verification should be off by default")
	}
	newIdentity(t).login(srv)
}
