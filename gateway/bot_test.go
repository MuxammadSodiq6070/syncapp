package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

// botAPI stands in for api.telegram.org and keeps what the bot said.
type botAPI struct {
	srv   *httptest.Server
	sent  []string
	calls []string
}

func newBotAPI(t *testing.T) *botAPI {
	t.Helper()
	api := &botAPI{}
	api.srv = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_ = r.ParseForm()
		parts := strings.Split(strings.Trim(r.URL.Path, "/"), "/")
		api.calls = append(api.calls, parts[len(parts)-1])
		if parts[len(parts)-1] == "sendMessage" {
			api.sent = append(api.sent, r.FormValue("text")+"|"+r.FormValue("reply_markup"))
		}
		fmt.Fprint(w, `{"ok":true,"result":{}}`)
	}))
	t.Cleanup(api.srv.Close)
	return api
}

func (a *botAPI) lastSent() string {
	if len(a.sent) == 0 {
		return ""
	}
	return a.sent[len(a.sent)-1]
}

func newBot(t *testing.T, store *Store) (*BotVerifier, *botAPI) {
	t.Helper()
	api := newBotAPI(t)
	hasher, err := NewPhoneHasher(strings.Repeat("k", 40))
	if err != nil {
		t.Fatal(err)
	}
	bot, err := NewBotVerifier("bot-token", "@SyncTestBot", store, hasher.Hash)
	if err != nil {
		t.Fatal(err)
	}
	bot.base = api.srv.URL
	return bot, api
}

// update posts a webhook update the way Telegram would, with the secret header.
func (b *BotVerifier) update(t *testing.T, body map[string]any, secret string) int {
	t.Helper()
	raw, _ := json.Marshal(map[string]any{"message": body})
	r := httptest.NewRequest(http.MethodPost, "/bot/update", bytes.NewReader(raw))
	r.Header.Set("X-Telegram-Bot-Api-Secret-Token", secret)
	w := httptest.NewRecorder()
	b.HandleUpdate(w, r)
	return w.Code
}

func startMsg(from int64, nonce string) map[string]any {
	return map[string]any{
		"from": map[string]any{"id": from},
		"chat": map[string]any{"id": from},
		"text": "/start " + nonce,
	}
}

func contactMsg(from, contactUser int64, phone string) map[string]any {
	return map[string]any{
		"from":    map[string]any{"id": from},
		"chat":    map[string]any{"id": from},
		"contact": map[string]any{"phone_number": phone, "user_id": contactUser},
	}
}

func TestBotSignUpEndToEnd(t *testing.T) {
	store := testStore(t)
	bot, api := newBot(t, store)
	ctx := context.Background()

	nonce, link, err := bot.Start(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(link, "t.me/SyncTestBot?start="+nonce) {
		t.Fatalf("link %q", link)
	}
	// Nothing is proven yet.
	if _, err := bot.Poll(ctx, nonce); err == nil {
		t.Fatal("a ticket was handed out before the bot proved anything")
	}

	if code := bot.update(t, startMsg(555, nonce), bot.secret); code != http.StatusOK {
		t.Fatalf("start update: %d", code)
	}
	// The bot must offer the button that makes Telegram supply the number.
	if !strings.Contains(api.lastSent(), "request_contact") {
		t.Fatalf("bot did not ask for the number: %q", api.lastSent())
	}
	if _, err := bot.Poll(ctx, nonce); err == nil {
		t.Fatal("pressing start alone proved a number")
	}

	bot.update(t, contactMsg(555, 555, "+998901112233"), bot.secret)
	ticket, err := bot.Poll(ctx, nonce)
	if err != nil {
		t.Fatalf("no ticket after the number was shared: %v", err)
	}

	hash, err := bot.Consume(ctx, ticket)
	if err != nil {
		t.Fatal(err)
	}
	hasher, _ := NewPhoneHasher(strings.Repeat("k", 40))
	if hash != hasher.Hash("+998901112233") {
		t.Fatal("the ticket carried the wrong number")
	}
	// Single use: a stolen ticket is worthless once spent.
	if _, err := bot.Consume(ctx, ticket); err == nil {
		t.Fatal("the same ticket registered twice")
	}
}

// A contact card can be forwarded. Without this check anyone could sign up as
// anyone whose card they had been sent.
func TestBotRefusesSomeoneElsesNumber(t *testing.T) {
	store := testStore(t)
	bot, api := newBot(t, store)
	ctx := context.Background()
	nonce, _, _ := bot.Start(ctx)
	bot.update(t, startMsg(555, nonce), bot.secret)

	bot.update(t, contactMsg(555, 999, "+998901112233"), bot.secret) // forwarded card
	if _, err := bot.Poll(ctx, nonce); err == nil {
		t.Fatal("a forwarded contact proved a number")
	}
	if !strings.Contains(api.lastSent(), "o‘zingizning") {
		t.Fatalf("the bot did not explain why: %q", api.lastSent())
	}
	// A contact with no user id at all is not proof either.
	bot.update(t, contactMsg(555, 0, "+998901112233"), bot.secret)
	if _, err := bot.Poll(ctx, nonce); err == nil {
		t.Fatal("a contact without a user id proved a number")
	}
}

// The webhook path is public, so the shared secret is the only thing standing
// between a stranger and a free account.
func TestBotWebhookNeedsTheSecret(t *testing.T) {
	store := testStore(t)
	bot, _ := newBot(t, store)
	ctx := context.Background()
	nonce, _, _ := bot.Start(ctx)

	if code := bot.update(t, startMsg(555, nonce), "wrong-secret"); code != http.StatusForbidden {
		t.Fatalf("a forged update was accepted: %d", code)
	}
	if code := bot.update(t, startMsg(555, nonce), ""); code != http.StatusForbidden {
		t.Fatalf("an update with no secret was accepted: %d", code)
	}
	bot.update(t, contactMsg(555, 555, "+998901112233"), "wrong-secret")
	if _, err := bot.Poll(ctx, nonce); err == nil {
		t.Fatal("a forged contact proved a number")
	}
}

func TestBotRefusesANumberThatAlreadyHasAnAccount(t *testing.T) {
	store := testStore(t)
	bot, api := newBot(t, store)
	ctx := context.Background()
	hasher, _ := NewPhoneHasher(strings.Repeat("k", 40))
	if _, err := store.Register("aa"+strings.Repeat("0", 62), "pk", "sig",
		hasher.Hash("+998901112233")); err != nil {
		t.Fatal(err)
	}
	nonce, _, _ := bot.Start(ctx)
	bot.update(t, startMsg(555, nonce), bot.secret)
	bot.update(t, contactMsg(555, 555, "+998901112233"), bot.secret)

	if _, err := bot.Poll(ctx, nonce); err == nil {
		t.Fatal("a second account was allowed on one number")
	}
	if !strings.Contains(api.lastSent(), "allaqachon") {
		t.Fatalf("the bot did not say the number is taken: %q", api.lastSent())
	}
}

// An old link must not be usable, or a nonce seen once could be replayed later.
func TestBotLinkExpires(t *testing.T) {
	store := testStore(t)
	bot, api := newBot(t, store)
	ctx := context.Background()
	nonce, _, _ := bot.Start(ctx)
	stale := time.Now().Add(-2 * botNonceTTL).UnixMilli()
	if _, err := store.db.Exec(ctx,
		`UPDATE sync_gateway.bot_verifications SET created_at = $1`, stale); err != nil {
		t.Fatal(err)
	}
	bot.update(t, startMsg(555, nonce), bot.secret)
	if !strings.Contains(api.lastSent(), "muddati tugadi") {
		t.Fatalf("an expired link was accepted: %q", api.lastSent())
	}
	bot.update(t, contactMsg(555, 555, "+998901112233"), bot.secret)
	if _, err := bot.Poll(ctx, nonce); err == nil {
		t.Fatal("an expired link still produced a ticket")
	}
}

// Opening the bot without coming from the app should explain itself rather than
// looking broken.
func TestBotWithoutALinkExplainsItself(t *testing.T) {
	store := testStore(t)
	bot, api := newBot(t, store)
	bot.update(t, startMsg(555, ""), bot.secret)
	if !strings.Contains(api.lastSent(), "Sync ilovasini oching") {
		t.Fatalf("unhelpful reply: %q", api.lastSent())
	}
}

// The whole point of the bot path: registering needs a ticket and nothing else.
func TestRegisterThroughTheBot(t *testing.T) {
	srv, store, _, hub := newServer(t)
	bot, _ := newBot(t, store)
	hub.bot = bot
	ctx := context.Background()

	a := newIdentity(t)
	if r := a.authAs(srv, map[string]any{}); r != "verification_required" {
		t.Fatalf("registered with no ticket: %q", r)
	}
	if r := a.authAs(srv, map[string]any{"ticket": strings.Repeat("f", 32)}); r != "invalid_ticket" {
		t.Fatalf("a made-up ticket was accepted: %q", r)
	}

	nonce, _, _ := bot.Start(ctx)
	bot.update(t, startMsg(777, nonce), bot.secret)
	bot.update(t, contactMsg(777, 777, "+998905550123"), bot.secret)
	ticket, err := bot.Poll(ctx, nonce)
	if err != nil {
		t.Fatal(err)
	}
	if r := a.authAs(srv, map[string]any{"ticket": ticket}); r != "" {
		t.Fatalf("a proven number was refused: %q", r)
	}
	// Coming back needs no ticket at all.
	again := &testClient{t: t, id: a.id, pk: a.pk, sk: a.sk, box: a.box}
	if r := again.authAs(srv, map[string]any{}); r != "" {
		t.Fatalf("an existing account was asked to verify again: %q", r)
	}
	// And that ticket cannot open a second account.
	b := newIdentity(t)
	if r := b.authAs(srv, map[string]any{"ticket": ticket}); r == "" {
		t.Fatal("one ticket opened two accounts")
	}
}

func TestSweepBotVerificationsDropsAbandonedLinks(t *testing.T) {
	store := testStore(t)
	ctx := context.Background()
	if err := store.StartBotVerification(ctx, strings.Repeat("a", 32)); err != nil {
		t.Fatal(err)
	}
	stale := time.Now().Add(-10 * (botNonceTTL + botTicketTTL)).UnixMilli()
	if _, err := store.db.Exec(ctx,
		`UPDATE sync_gateway.bot_verifications SET created_at = $1`, stale); err != nil {
		t.Fatal(err)
	}
	if err := store.SweepBotVerifications(ctx); err != nil {
		t.Fatal(err)
	}
	var n int
	if err := store.db.QueryRow(ctx,
		`SELECT count(*) FROM sync_gateway.bot_verifications`).Scan(&n); err != nil {
		t.Fatal(err)
	}
	if n != 0 {
		t.Fatalf("%d abandoned links were kept", n)
	}
}
