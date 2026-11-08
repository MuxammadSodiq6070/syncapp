package main

import (
	"context"
	"crypto"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"math/big"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

const testProject = "syncapp-test"

func newTestVerifierKey(seed string) (*Verifier, error) {
	h, err := NewPhoneHasher(strings.Repeat(seed, 32))
	if err != nil {
		return nil, err
	}
	return NewVerifier(testProject, h)
}

func newTestVerifier() (*Verifier, error) { return newTestVerifierKey("k") }

// fakeGoogle serves certificates the way Google's endpoint does, so the verifier is
// exercised exactly as it will be in production, minus the network.
type fakeGoogle struct {
	key    *rsa.PrivateKey
	kid    string
	srv    *httptest.Server
	hits   atomic.Int32
	maxAge string
}

func newFakeGoogle(t *testing.T) *fakeGoogle {
	t.Helper()
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	tmpl := &x509.Certificate{SerialNumber: big.NewInt(1), Subject: pkix.Name{CommonName: "test"},
		NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(time.Hour)}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	g := &fakeGoogle{key: key, kid: "kid-1", maxAge: "public, max-age=3600"}
	certPEM := string(pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}))
	g.srv = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		g.hits.Add(1)
		w.Header().Set("Cache-Control", g.maxAge)
		json.NewEncoder(w).Encode(map[string]string{g.kid: certPEM})
	}))
	t.Cleanup(g.srv.Close)
	return g
}

func (g *fakeGoogle) verifier(t *testing.T) *Verifier {
	t.Helper()
	v, err := newTestVerifier()
	if err != nil {
		t.Fatal(err)
	}
	v.certsURL = g.srv.URL
	return v
}

type claimEdit func(map[string]any)

func (g *fakeGoogle) token(t *testing.T, edits ...claimEdit) string {
	t.Helper()
	now := time.Now()
	claims := map[string]any{
		"iss": "https://securetoken.google.com/" + testProject,
		"aud": testProject, "sub": "uid-1",
		"iat": now.Add(-time.Minute).Unix(), "exp": now.Add(time.Hour).Unix(),
		"auth_time": now.Add(-time.Minute).Unix(), "phone_number": "+998901234567",
		"firebase": map[string]any{"sign_in_provider": "phone"},
	}
	for _, e := range edits {
		e(claims)
	}
	return g.sign(t, map[string]any{"alg": "RS256", "kid": g.kid, "typ": "JWT"}, claims)
}

func (g *fakeGoogle) sign(t *testing.T, header, claims map[string]any) string {
	t.Helper()
	enc := func(v any) string {
		b, err := json.Marshal(v)
		if err != nil {
			t.Fatal(err)
		}
		return base64.RawURLEncoding.EncodeToString(b)
	}
	body := enc(header) + "." + enc(claims)
	digest := sha256.Sum256([]byte(body))
	sig, err := rsa.SignPKCS1v15(rand.Reader, g.key, crypto.SHA256, digest[:])
	if err != nil {
		t.Fatal(err)
	}
	return body + "." + base64.RawURLEncoding.EncodeToString(sig)
}

func TestVerifierAcceptsGenuineToken(t *testing.T) {
	g := newFakeGoogle(t)
	v := g.verifier(t)
	phone, err := v.VerifyPhone(context.Background(), g.token(t))
	if err != nil || phone != "+998901234567" {
		t.Fatalf("got %q %v", phone, err)
	}
	// The certificates are cached, not fetched per token.
	for i := 0; i < 5; i++ {
		if _, err := v.VerifyPhone(context.Background(), g.token(t)); err != nil {
			t.Fatal(err)
		}
	}
	if n := g.hits.Load(); n != 1 {
		t.Fatalf("fetched certificates %d times", n)
	}
}

func TestVerifierRejectsEveryForgery(t *testing.T) {
	g := newFakeGoogle(t)
	v := g.verifier(t)
	other, _ := rsa.GenerateKey(rand.Reader, 2048)

	cases := map[string]string{
		"not a jwt":        "garbage",
		"empty":            "",
		"two parts":        "a.b",
		"another project":  g.token(t, func(c map[string]any) { c["aud"] = "someone-else" }),
		"wrong issuer":     g.token(t, func(c map[string]any) { c["iss"] = "https://securetoken.google.com/evil" }),
		"expired":          g.token(t, func(c map[string]any) { c["exp"] = time.Now().Add(-2 * time.Hour).Unix() }),
		"issued in future": g.token(t, func(c map[string]any) { c["iat"] = time.Now().Add(time.Hour).Unix() }),
		"no phone":         g.token(t, func(c map[string]any) { delete(c, "phone_number") }),
		"not a phone login": g.token(t, func(c map[string]any) {
			c["firebase"] = map[string]any{"sign_in_provider": "anonymous"}
		}),
		"no subject": g.token(t, func(c map[string]any) { c["sub"] = "" }),
	}
	for name, tok := range cases {
		if _, err := v.VerifyPhone(context.Background(), tok); err == nil {
			t.Errorf("%s was accepted", name)
		}
	}

	// Correctly shaped, signed by someone else.
	forger := &fakeGoogle{key: other, kid: g.kid}
	if _, err := v.VerifyPhone(context.Background(), forger.token(t)); err == nil {
		t.Error("a token signed with another key was accepted")
	}
	// "alg: none", the classic JWT bypass.
	none := g.sign(t, map[string]any{"alg": "none", "kid": g.kid}, map[string]any{
		"aud": testProject, "iss": "https://securetoken.google.com/" + testProject,
		"sub": "x", "exp": time.Now().Add(time.Hour).Unix(), "phone_number": "+998901234567",
		"firebase": map[string]any{"sign_in_provider": "phone"},
	})
	if _, err := v.VerifyPhone(context.Background(), none); err == nil {
		t.Error("alg:none was accepted")
	}
}

// A leaked database must not reveal who holds which number.
func TestPhoneHashIsKeyed(t *testing.T) {
	a, err := newTestVerifierKey("a")
	if err != nil {
		t.Fatal(err)
	}
	b, _ := newTestVerifierKey("b")
	phone := "+998901234567"
	if a.PhoneHash(phone) == b.PhoneHash(phone) {
		t.Fatal("the hash does not depend on the key")
	}
	if a.PhoneHash(phone) != a.PhoneHash(phone) {
		t.Fatal("the hash is not stable")
	}
	if strings.Contains(a.PhoneHash(phone), "998") {
		t.Fatal("the number leaks into the hash")
	}
	if _, err := NewPhoneHasher("short"); err == nil {
		t.Fatal("a weak hash key was accepted")
	}
	if _, err := NewVerifier(testProject, nil); err == nil {
		t.Fatal("a project id without a hash key was accepted")
	}
	if v, err := NewVerifier("", nil); v != nil || err != nil {
		t.Fatal("no project id should leave verification off")
	}
}

func TestCacheForClampsMaxAge(t *testing.T) {
	for header, want := range map[string]time.Duration{
		"public, max-age=3600": time.Hour,
		"max-age=1":            certRefreshFloor,
		"max-age=999999999":    certRefreshMax,
		"":                     time.Hour,
		"no-cache":             time.Hour,
	} {
		if got := cacheFor(header); got != want {
			t.Errorf("%q: got %v want %v", header, got, want)
		}
	}
}
