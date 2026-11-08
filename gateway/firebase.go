package main

import (
	"context"
	"crypto"
	"crypto/hmac"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
	"sync"
	"time"
)

// Google's public certificates for Firebase ID tokens.
const googleCertsURL = "https://www.googleapis.com/robot/v1/metadata/x509/securetoken@system.gserviceaccount.com"

const (
	certRefreshFloor = time.Minute
	certRefreshMax   = 24 * time.Hour
	clockSkew        = time.Minute
)

var (
	errNoToken      = errors.New("verification_required")
	errBadToken     = errors.New("verification_failed")
	errPhoneInUse   = errors.New("phone_already_used")
	errVerifierDown = errors.New("verification_unavailable")
)

// PhoneHasher turns a number into the only form the gateway ever stores. It is keyed
// because phone numbers have far too little entropy for a plain hash to hide them if
// the database leaks.
type PhoneHasher struct{ key []byte }

func NewPhoneHasher(key string) (*PhoneHasher, error) {
	if len(key) < 32 {
		return nil, errors.New("SYNC_PHONE_HASH_KEY must be at least 32 characters")
	}
	return &PhoneHasher{key: []byte(key)}, nil
}

func (p *PhoneHasher) Hash(phone string) string {
	m := hmac.New(sha256.New, p.key)
	m.Write([]byte(phone))
	return hex.EncodeToString(m.Sum(nil))
}

// Verifier checks Firebase ID tokens, so the gateway decides who may register
// rather than trusting the app to have asked for an SMS code.
type Verifier struct {
	projectID string
	certsURL  string
	hasher    *PhoneHasher
	http      *http.Client

	mu      sync.RWMutex
	certs   map[string]*rsa.PublicKey
	expires time.Time
}

// NewVerifier returns nil when no project id is given, which leaves the Firebase
// path switched off.
func NewVerifier(projectID string, hasher *PhoneHasher) (*Verifier, error) {
	if projectID == "" {
		return nil, nil
	}
	if hasher == nil {
		return nil, errors.New("FIREBASE_PROJECT_ID needs SYNC_PHONE_HASH_KEY too")
	}
	return &Verifier{
		projectID: projectID,
		certsURL:  googleCertsURL,
		hasher:    hasher,
		http:      &http.Client{Timeout: 10 * time.Second},
		certs:     map[string]*rsa.PublicKey{},
	}, nil
}

// PhoneHash is what the gateway stores instead of the number itself.
func (v *Verifier) PhoneHash(phone string) string { return v.hasher.Hash(phone) }

func (v *Verifier) keyFor(ctx context.Context, kid string) (*rsa.PublicKey, error) {
	v.mu.RLock()
	key, ok := v.certs[kid]
	fresh := time.Now().Before(v.expires)
	v.mu.RUnlock()
	if ok && fresh {
		return key, nil
	}
	if err := v.refresh(ctx); err != nil {
		// A cached key is better than refusing everyone when Google is unreachable.
		if ok {
			return key, nil
		}
		return nil, err
	}
	v.mu.RLock()
	defer v.mu.RUnlock()
	if key, ok := v.certs[kid]; ok {
		return key, nil
	}
	return nil, errBadToken
}

func (v *Verifier) refresh(ctx context.Context) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, v.certsURL, nil)
	if err != nil {
		return err
	}
	resp, err := v.http.Do(req)
	if err != nil {
		return fmt.Errorf("fetch google certs: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("fetch google certs: %d", resp.StatusCode)
	}
	var raw map[string]string
	if err := json.NewDecoder(io.LimitReader(resp.Body, 1<<20)).Decode(&raw); err != nil {
		return fmt.Errorf("parse google certs: %w", err)
	}
	keys := make(map[string]*rsa.PublicKey, len(raw))
	for kid, certPEM := range raw {
		block, _ := pem.Decode([]byte(certPEM))
		if block == nil {
			continue
		}
		cert, err := x509.ParseCertificate(block.Bytes)
		if err != nil {
			continue
		}
		if pub, ok := cert.PublicKey.(*rsa.PublicKey); ok {
			keys[kid] = pub
		}
	}
	if len(keys) == 0 {
		return errors.New("google returned no usable certificates")
	}
	v.mu.Lock()
	v.certs = keys
	v.expires = time.Now().Add(cacheFor(resp.Header.Get("Cache-Control")))
	v.mu.Unlock()
	return nil
}

// cacheFor reads max-age, clamped so a missing or absurd value cannot pin stale keys.
func cacheFor(header string) time.Duration {
	for _, part := range strings.Split(header, ",") {
		part = strings.TrimSpace(part)
		if after, ok := strings.CutPrefix(part, "max-age="); ok {
			var secs int
			if _, err := fmt.Sscanf(after, "%d", &secs); err == nil {
				d := time.Duration(secs) * time.Second
				return min(max(d, certRefreshFloor), certRefreshMax)
			}
		}
	}
	return time.Hour
}

func b64url(s string) ([]byte, error) { return base64.RawURLEncoding.DecodeString(s) }

type idTokenClaims struct {
	Iss      string `json:"iss"`
	Aud      string `json:"aud"`
	Sub      string `json:"sub"`
	Exp      int64  `json:"exp"`
	Iat      int64  `json:"iat"`
	AuthTime int64  `json:"auth_time"`
	Phone    string `json:"phone_number"`
	Firebase struct {
		SignInProvider string `json:"sign_in_provider"`
	} `json:"firebase"`
}

// VerifyPhone checks a Firebase ID token and returns the verified phone number.
// Everything the token asserts is checked here; nothing is taken on trust.
func (v *Verifier) VerifyPhone(ctx context.Context, token string) (string, error) {
	parts := strings.Split(token, ".")
	if len(parts) != 3 {
		return "", errBadToken
	}
	headerJSON, err := b64url(parts[0])
	if err != nil {
		return "", errBadToken
	}
	var header struct {
		Alg string `json:"alg"`
		Kid string `json:"kid"`
	}
	if json.Unmarshal(headerJSON, &header) != nil || header.Alg != "RS256" || header.Kid == "" {
		return "", errBadToken
	}
	key, err := v.keyFor(ctx, header.Kid)
	if err != nil {
		if errors.Is(err, errBadToken) {
			return "", errBadToken
		}
		return "", errVerifierDown
	}
	sig, err := b64url(parts[2])
	if err != nil {
		return "", errBadToken
	}
	digest := sha256.Sum256([]byte(parts[0] + "." + parts[1]))
	if rsa.VerifyPKCS1v15(key, crypto.SHA256, digest[:], sig) != nil {
		return "", errBadToken
	}
	payload, err := b64url(parts[1])
	if err != nil {
		return "", errBadToken
	}
	var c idTokenClaims
	if json.Unmarshal(payload, &c) != nil {
		return "", errBadToken
	}
	now := time.Now()
	switch {
	case c.Aud != v.projectID:
		return "", errBadToken
	case c.Iss != "https://securetoken.google.com/"+v.projectID:
		return "", errBadToken
	case c.Sub == "":
		return "", errBadToken
	case now.After(time.Unix(c.Exp, 0).Add(clockSkew)):
		return "", errBadToken
	case now.Before(time.Unix(c.Iat, 0).Add(-clockSkew)):
		return "", errBadToken
	case c.AuthTime > 0 && now.Before(time.Unix(c.AuthTime, 0).Add(-clockSkew)):
		return "", errBadToken
	case c.Firebase.SignInProvider != "phone":
		return "", errBadToken
	case !strings.HasPrefix(c.Phone, "+") || len(c.Phone) < 8:
		return "", errBadToken
	}
	return c.Phone, nil
}
