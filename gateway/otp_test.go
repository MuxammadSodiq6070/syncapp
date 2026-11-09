package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"sync"
	"testing"
	"time"
)

// recorder stands in for the code provider and keeps what would have been sent.
type recorder struct {
	mu   sync.Mutex
	sent []string
	fail error
}

func (r *recorder) Via() string { return "sms" }

func (r *recorder) Send(_ context.Context, phone, code string) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.fail != nil {
		return r.fail
	}
	r.sent = append(r.sent, phone+" "+code)
	return nil
}

func (r *recorder) codes() []string {
	r.mu.Lock()
	defer r.mu.Unlock()
	out := []string{}
	for _, m := range r.sent {
		_, code, _ := strings.Cut(m, " ")
		out = append(out, code)
	}
	return out
}

func newOTP(t *testing.T) (*OTPService, *recorder, *Store) {
	t.Helper()
	store := testStore(t)
	rec := &recorder{}
	v, err := newTestVerifier()
	if err != nil {
		t.Fatal(err)
	}
	return NewOTPService(store, rec, v.PhoneHash, 1000), rec, store
}

func TestNormalizePhone(t *testing.T) {
	for raw, want := range map[string]string{
		"+998901234567":       "+998901234567",
		"998 90 123 4567":     "+998901234567",
		"+998 (90) 123-45-67": "+998901234567",
	} {
		got, err := normalizePhone(raw)
		if err != nil || got != want {
			t.Errorf("%q → %q %v", raw, got, err)
		}
	}
	for _, bad := range []string{"", "+", "abc", "12", "+0123456789", "+9989012345678901234", "998901234567x"} {
		if got, err := normalizePhone(bad); err == nil {
			t.Errorf("%q was accepted as %q", bad, got)
		}
	}
}

func TestCodeFlow(t *testing.T) {
	o, rec, store := newOTP(t)
	ctx := context.Background()
	phone := "+998901234567"

	if err := o.Request(ctx, phone); err != nil {
		t.Fatal(err)
	}
	codes := rec.codes()
	if len(codes) != 1 {
		t.Fatalf("expected one code, got %v", rec.sent)
	}
	code := codes[0]

	// The code itself is never stored.
	var stored string
	store.db.QueryRow(ctx, `SELECT code_hash FROM sync_gateway.signup_codes`).Scan(&stored)
	if stored == code || strings.Contains(stored, code) {
		t.Fatal("the code is recoverable from the database")
	}

	// A wrong code fails, and the right one then works once.
	if _, err := o.Check(ctx, phone, "000000"); err != errBadCode && err != nil {
		t.Fatalf("wrong code: %v", err)
	}
	if _, err := o.Check(ctx, phone, code); err != nil {
		t.Fatalf("right code refused: %v", err)
	}
	if _, err := o.Check(ctx, phone, code); err == nil {
		t.Fatal("the code worked twice")
	}

	// Spacing in the number does not create a second identity.
	if err := o.Request(ctx, phone); err != errTooSoon {
		t.Fatalf("resend wait skipped: %v", err)
	}
	if err := o.Request(ctx, "998 90 123 45 67"); err != errTooSoon {
		t.Fatalf("respacing the number bypassed the wait: %v", err)
	}
}

func TestCodeGuessingIsLimited(t *testing.T) {
	o, rec, _ := newOTP(t)
	ctx := context.Background()
	phone := "+998901110000"
	if err := o.Request(ctx, phone); err != nil {
		t.Fatal(err)
	}
	code := rec.codes()[0]
	for i := 0; i < codeMaxAttempts; i++ {
		if _, err := o.Check(ctx, phone, "000001"); err != errBadCode {
			t.Fatalf("attempt %d: %v", i, err)
		}
	}
	// Spent: even the right code no longer works.
	if _, err := o.Check(ctx, phone, code); err == nil {
		t.Fatal("guessing was not limited")
	}
}

func TestCodeExpires(t *testing.T) {
	o, rec, store := newOTP(t)
	ctx := context.Background()
	phone := "+998901110001"
	if err := o.Request(ctx, phone); err != nil {
		t.Fatal(err)
	}
	code := rec.codes()[0]
	if _, err := store.db.Exec(ctx, `UPDATE sync_gateway.signup_codes SET expires_at = $1`,
		time.Now().Add(-time.Minute).UnixMilli()); err != nil {
		t.Fatal(err)
	}
	if _, err := o.Check(ctx, phone, code); err != errCodeExpired {
		t.Fatalf("expired code: %v", err)
	}
	if err := store.SweepCodes(ctx, time.Now()); err != nil {
		t.Fatal(err)
	}
}

// Money: neither one number nor the whole service may send without bound.
func TestSMSSpendIsBounded(t *testing.T) {
	o, _, store := newOTP(t)
	ctx := context.Background()
	phone := "+998901110002"
	ageOut := func() {
		store.db.Exec(ctx, `UPDATE sync_gateway.signup_codes SET sent_at = $1`,
			time.Now().Add(-2*time.Minute).UnixMilli())
	}
	for i := 0; i < codePerPhoneDay; i++ {
		if err := o.Request(ctx, phone); err != nil {
			t.Fatalf("send %d: %v", i, err)
		}
		ageOut()
	}
	if err := o.Request(ctx, phone); err != errPhoneQuota {
		t.Fatalf("daily cap for one number: %v", err)
	}

	o.budget = 1
	store.db.Exec(ctx, `UPDATE sync_gateway.sms_budget SET sent = 1`)
	if err := o.Request(ctx, "+998901110003"); err != errSMSBudget {
		t.Fatalf("service budget: %v", err)
	}
}

// A number that already has an account still gets a code: that is how someone signs
// in from another phone. Refusing here would lock them out of their own number.
func TestCodeStillSentToARegisteredNumber(t *testing.T) {
	o, rec, store := newOTP(t)
	ctx := context.Background()
	phone := "+998901110004"
	hash := o.phoneHash(phone)
	if _, err := store.Register(strings.Repeat("a", 64), "pk", "sig", hash); err != nil {
		t.Fatal(err)
	}
	if err := o.Request(ctx, phone); err != nil {
		t.Fatalf("no code for a number that already has an account: %v", err)
	}
	if len(rec.codes()) != 1 {
		t.Fatalf("codes sent: %d", len(rec.codes()))
	}
}

// The whole path: ask over HTTP, then register over the socket.
func TestSignUpWithCode(t *testing.T) {
	store := testStore(t)
	rec := &recorder{}
	v, _ := newTestVerifier()
	dir := t.TempDir()
	blobs, _ := NewDiskBlobs(dir + "/m")
	media, _ := NewMediaStore(store, blobs, MediaLimits{PerOwner: 1 << 20, Total: 1 << 20, TTL: time.Hour}, dir+"/s")
	hub := NewHub(store, media)
	hub.verifier = v
	hub.otp = NewOTPService(store, rec, v.PhoneHash, 1000)
	srv := httptest.NewServer(hub.Routes())
	defer func() {
		hub.CloseAll()
		srv.Close()
	}()

	ask := func(phone string) map[string]any {
		body, _ := json.Marshal(map[string]string{"phone": phone})
		resp, err := http.Post(srv.URL+"/verify/request", "application/json", strings.NewReader(string(body)))
		if err != nil {
			t.Fatal(err)
		}
		defer resp.Body.Close()
		var out map[string]any
		json.NewDecoder(resp.Body).Decode(&out)
		return out
	}

	a := newIdentity(t)
	if r := a.tryLogin(srv, ""); r != "verification_required" {
		t.Fatalf("registered with no code: %q", r)
	}

	phone := "+998905550001"
	if out := ask(phone); out["ok"] != true {
		t.Fatalf("request: %v", out)
	}
	code := rec.codes()[0]

	// A wrong code does not register anyone.
	if r := a.tryLoginWithCode(srv, phone, "000000"); r != "invalid_code" {
		t.Fatalf("wrong code: %q", r)
	}
	if r := a.tryLoginWithCode(srv, phone, code); r != "" {
		t.Fatalf("right code refused: %q", r)
	}
	// The number keeps working: a second device asks for a code and takes the
	// account over, which is what moving phones looks like.
	store.db.Exec(context.Background(),
		`UPDATE sync_gateway.signup_codes SET sent_at = 0, sent_today = 0`)
	if out := ask(phone); out["ok"] != true {
		t.Fatalf("a registered number was refused a code: %v", out)
	}
	moved := newIdentity(t)
	if r := moved.tryLoginWithCode(srv, phone, rec.codes()[len(rec.codes())-1]); r != "" {
		t.Fatalf("the second device was refused: %q", r)
	}
	// The first identity lost the number, so it has to verify again to come back.
	if r := a.tryLogin(srv, ""); r != "verification_required" {
		t.Fatalf("the displaced identity stayed signed in: %q", r)
	}
	// The identity that holds the number now comes back with nothing: this is the
	// recovery-key path, and it must never ask for a code again.
	again := &testClient{t: t, id: moved.id, pk: moved.pk, sk: moved.sk, box: moved.box}
	if r := again.tryLogin(srv, ""); r != "" {
		t.Fatalf("existing account asked to verify: %q", r)
	}
	// Rubbish input is refused before any message is sent.
	before := len(rec.codes())
	if out := ask("not a phone"); out["error"] != "invalid_phone" {
		t.Fatalf("bad phone: %v", out)
	}
	if len(rec.codes()) != before {
		t.Fatal("a message was sent for an invalid number")
	}
}

func TestEskizSenderTalksToTheAPI(t *testing.T) {
	var gotAuth string
	var gotForm string
	logins := 0
	api := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		r.ParseForm()
		switch r.URL.Path {
		case "/api/auth/login":
			logins++
			if r.FormValue("email") == "" || r.FormValue("password") == "" {
				t.Error("login without credentials")
			}
			fmt.Fprintf(w, `{"data":{"token":"tok-%d"}}`, logins)
		case "/api/message/sms/send":
			gotAuth = r.Header.Get("Authorization")
			gotForm = r.Form.Encode()
			if gotAuth == "Bearer tok-1" {
				w.WriteHeader(http.StatusUnauthorized) // expired, as Eskiz does
				return
			}
			w.WriteHeader(http.StatusOK)
		}
	}))
	defer api.Close()
	e := NewEskizSender("me@example.com", "pw", "", "Sync kodi: %s")
	e.base = api.URL
	if err := e.Send(context.Background(), "+998901234567", "123456"); err != nil {
		t.Fatal(err)
	}
	// The approved template is the sender's job, so the code must arrive inside it.
	if !strings.Contains(gotForm, url.QueryEscape("Sync kodi: 123456")) {
		t.Fatalf("the code was not put through the template: %s", gotForm)
	}
	if logins != 2 {
		t.Fatalf("expected a re-login after the token was rejected, got %d logins", logins)
	}
	if !strings.Contains(gotForm, "mobile_phone=998901234567") {
		t.Fatalf("the plus should be stripped: %s", gotForm)
	}
	if gotAuth != "Bearer tok-2" {
		t.Fatalf("auth header %q", gotAuth)
	}
}
