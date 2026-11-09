package main

import (
	"context"
	"strings"
	"testing"
	"time"
)

// A reserved name is not an identity, and must never become one.
func TestReservedNamesCannotBeIdentities(t *testing.T) {
	for _, id := range []string{"service", "saved", ""} {
		if err := checkID(id); err == nil {
			t.Fatalf("%q was accepted as an identity", id)
		}
	}
	if err := checkID("abc123"); err != nil {
		t.Fatalf("an ordinary id was refused: %v", err)
	}
}

func TestNewAccountIsGreetedBySync(t *testing.T) {
	srv, _, _, _ := newServer(t)
	a := newIdentity(t)
	a.login(srv)
	m := a.readType("service")
	if m["kind"] != "welcome" {
		t.Fatalf("first service message was %v", m)
	}
	body, _ := m["body"].(map[string]any)
	if body["text"] != "welcome" {
		t.Fatalf("body %v: the app needs a name to translate, not a sentence", body)
	}
	if m["id"] == "" || m["ts"] == nil {
		t.Fatalf("a service message needs an id and a time: %v", m)
	}
}

// Someone signing in on another device is the one thing this chat exists to report.
func TestSignInFromAnotherDeviceIsReported(t *testing.T) {
	srv, _, _, _ := newServer(t)
	a := newIdentity(t)
	if r := a.authAs(srv, map[string]any{"device": "device-one"}); r != "" {
		t.Fatal(r)
	}
	if m := a.readType("service"); m["kind"] != "welcome" {
		t.Fatalf("expected the welcome first, got %v", m)
	}
	// The same device again says nothing: reconnecting is not a sign-in elsewhere.
	if r := a.authAs(srv, map[string]any{"device": "device-one"}); r != "" {
		t.Fatal(r)
	}
	a.silent("service", 300*time.Millisecond)

	// A different device does.
	if r := a.authAs(srv, map[string]any{"device": "device-two"}); r != "" {
		t.Fatal(r)
	}
	m := a.readType("service")
	if m["kind"] != "security" {
		t.Fatalf("service message %v", m)
	}
	body, _ := m["body"].(map[string]any)
	if body["text"] != "new_device" {
		t.Fatalf("body %v", body)
	}
	if body["at"] == nil || body["place"] == nil {
		t.Fatalf("a sign-in notice should say when and from where: %v", body)
	}
}

// An account that never reports a device must not be told it signed in elsewhere,
// or every existing install would get a false alarm on upgrade.
func TestAccountWithoutADeviceIsNotWarned(t *testing.T) {
	srv, _, _, _ := newServer(t)
	a := newIdentity(t)
	a.login(srv)
	if m := a.readType("service"); m["kind"] != "welcome" {
		t.Fatalf("expected the welcome, got %v", m)
	}
	a.login(srv)
	a.silent("service", 300*time.Millisecond)
}

// A notice is handed over once. Two devices racing must not both get it, and a
// reconnect must not replay what was already delivered.
func TestServiceMessageIsHandedOverOnce(t *testing.T) {
	store := testStore(t)
	ctx := context.Background()
	if err := store.QueueService(ctx, "someone", "security", map[string]any{"text": "new_device"}); err != nil {
		t.Fatal(err)
	}
	first, err := store.TakeService(ctx, "someone")
	if err != nil {
		t.Fatal(err)
	}
	if len(first) != 1 || first[0].Body["text"] != "new_device" {
		t.Fatalf("first take: %v", first)
	}
	again, err := store.TakeService(ctx, "someone")
	if err != nil {
		t.Fatal(err)
	}
	if len(again) != 0 {
		t.Fatalf("the same notice was handed over twice: %v", again)
	}
}

// A notice waits for a device that is offline, rather than being lost.
func TestServiceMessageWaitsForTheDevice(t *testing.T) {
	srv, store, _, _ := newServer(t)
	a := newIdentity(t)
	a.login(srv)
	a.readType("service") // the welcome
	a.ws.Close()

	if err := store.QueueService(context.Background(), a.id, "security",
		map[string]any{"text": "new_device"}); err != nil {
		t.Fatal(err)
	}
	a.login(srv)
	if m := a.readType("service"); m["kind"] != "security" {
		t.Fatalf("the waiting notice did not arrive: %v", m)
	}
}

func TestSweepServiceDropsOldNotices(t *testing.T) {
	store := testStore(t)
	ctx := context.Background()
	if err := store.QueueService(ctx, "someone", "welcome", map[string]any{"text": "welcome"}); err != nil {
		t.Fatal(err)
	}
	old := time.Now().Add(-2 * serviceRetention).UnixMilli()
	if _, err := store.db.Exec(ctx,
		`UPDATE sync_gateway.service_messages SET created_at = $1`, old); err != nil {
		t.Fatal(err)
	}
	if err := store.SweepService(ctx); err != nil {
		t.Fatal(err)
	}
	left, err := store.TakeService(ctx, "someone")
	if err != nil {
		t.Fatal(err)
	}
	if len(left) != 0 {
		t.Fatalf("an abandoned notice was kept: %v", left)
	}
}

// Taking a number over must leave nothing of the previous account behind. The schema
// has no cascades, so the list of tables in forgetUser is hand-written: this test is
// what catches a table that was added later and forgotten there.
func TestTakeoverErasesThePreviousAccount(t *testing.T) {
	store := testStore(t)
	ctx := context.Background()
	hasher, err := NewPhoneHasher(strings.Repeat("k", 40))
	if err != nil {
		t.Fatal(err)
	}
	hash := hasher.Hash("+998901110099")
	old := "cc" + strings.Repeat("0", 62)
	if _, err := store.Register(old, "pk", "sig", hash); err != nil {
		t.Fatal(err)
	}
	// Give the old account something in every table that is keyed by an identity.
	if err := store.Enqueue(old, "someone", "blob"); err != nil {
		t.Fatal(err)
	}
	if err := store.QueueService(ctx, old, "welcome", map[string]any{"text": "welcome"}); err != nil {
		t.Fatal(err)
	}
	for _, q := range []struct {
		sql  string
		args []any
	}{
		{`INSERT INTO sync_gateway.watches (watcher, target) VALUES ($1, 'x')`, []any{old}},
		{`INSERT INTO sync_gateway.media (id, owner, bytes, created_at) VALUES ('m1', $1, 10, 0)`, []any{old}},
		{`INSERT INTO sync_gateway.market (id, seller, seller_name, title, price, description, category, created_at)
		  VALUES ('l1', $1, 'n', 't', 'p', 'd', 'c', 0)`, []any{old}},
	} {
		if _, err := store.db.Exec(ctx, q.sql, q.args...); err != nil {
			t.Fatalf("seeding: %v", err)
		}
	}

	fresh := "dd" + strings.Repeat("0", 62)
	if _, err := store.Register(fresh, "pk2", "sig2", hash); err != nil {
		t.Fatalf("takeover refused: %v", err)
	}

	for _, c := range []struct {
		what string
		sql  string
	}{
		{"users", `SELECT count(*) FROM sync_gateway.users WHERE id = $1`},
		{"queue", `SELECT count(*) FROM sync_gateway.queue WHERE recipient = $1 OR sender = $1`},
		{"queue_usage", `SELECT count(*) FROM sync_gateway.queue_usage WHERE recipient = $1`},
		{"queue_share", `SELECT count(*) FROM sync_gateway.queue_share WHERE recipient = $1 OR sender = $1`},
		{"watches", `SELECT count(*) FROM sync_gateway.watches WHERE watcher = $1 OR target = $1`},
		{"media", `SELECT count(*) FROM sync_gateway.media WHERE owner = $1`},
		{"market", `SELECT count(*) FROM sync_gateway.market WHERE seller = $1`},
		{"service_messages", `SELECT count(*) FROM sync_gateway.service_messages WHERE user_id = $1`},
	} {
		var n int
		if err := store.db.QueryRow(ctx, c.sql, old).Scan(&n); err != nil {
			t.Fatal(err)
		}
		if n != 0 {
			t.Errorf("%s: %d rows of the previous account survived", c.what, n)
		}
	}
	// And the number now belongs to the new identity alone.
	var holders int
	if err := store.db.QueryRow(ctx,
		`SELECT count(*) FROM sync_gateway.users WHERE phone_hash = $1`, hash).Scan(&holders); err != nil {
		t.Fatal(err)
	}
	if holders != 1 {
		t.Fatalf("%d identities hold the number", holders)
	}
}
