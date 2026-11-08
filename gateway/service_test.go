package main

import (
	"context"
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
