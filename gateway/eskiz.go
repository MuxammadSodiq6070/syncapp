package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"
)

const eskizBase = "https://notify.eskiz.uz"

// CodeSender is the one thing the verification flow needs from a provider: show this
// code to whoever owns this number. How it travels there, by SMS or through Telegram,
// is the provider's business.
type CodeSender interface {
	Send(ctx context.Context, phone, code string) error
	// Via names the road the code took, so the app can tell the person where to
	// look for it instead of guessing at an SMS that never arrives.
	Via() string
}

// EskizSender talks to notify.eskiz.uz. It logs in with the account's own
// credentials and keeps the bearer token until the API rejects it.
type EskizSender struct {
	base, email, password, from, template string
	http                                  *http.Client

	mu    sync.Mutex
	token string
}

func NewEskizSender(email, password, from, template string) *EskizSender {
	if from == "" {
		from = "4546" // Eskiz's shared sender id
	}
	if template == "" {
		// Eskiz delivers nothing that does not match a template its moderators have
		// approved, so this text and the approved one must agree exactly. That is an
		// Eskiz rule, which is why the text lives here and not in the OTP service.
		template = "Sync: tasdiqlash kodi %s. Hech kimga bermang."
	}
	return &EskizSender{
		base: eskizBase, email: email, password: password, from: from, template: template,
		http: &http.Client{Timeout: 20 * time.Second},
	}
}

func (e *EskizSender) login(ctx context.Context) (string, error) {
	form := url.Values{"email": {e.email}, "password": {e.password}}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, e.base+"/api/auth/login",
		strings.NewReader(form.Encode()))
	if err != nil {
		return "", err
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	resp, err := e.http.Do(req)
	if err != nil {
		return "", fmt.Errorf("eskiz login: %w", err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<16))
	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("eskiz login: %d", resp.StatusCode)
	}
	var out struct {
		Data struct {
			Token string `json:"token"`
		} `json:"data"`
	}
	if json.Unmarshal(body, &out) != nil || out.Data.Token == "" {
		return "", errors.New("eskiz login: no token in response")
	}
	return out.Data.Token, nil
}

func (e *EskizSender) bearer(ctx context.Context, force bool) (string, error) {
	e.mu.Lock()
	tok := e.token
	e.mu.Unlock()
	if tok != "" && !force {
		return tok, nil
	}
	tok, err := e.login(ctx)
	if err != nil {
		return "", err
	}
	e.mu.Lock()
	e.token = tok
	e.mu.Unlock()
	return tok, nil
}

func (e *EskizSender) Via() string { return "sms" }

// Send delivers one message, logging in again once if the token has expired.
func (e *EskizSender) Send(ctx context.Context, phone, code string) error {
	var lastErr error
	for attempt := 0; attempt < 2; attempt++ {
		tok, err := e.bearer(ctx, attempt > 0)
		if err != nil {
			return err
		}
		// Eskiz wants the number without a leading plus.
		form := url.Values{
			"mobile_phone": {strings.TrimPrefix(phone, "+")},
			"message":      {fmt.Sprintf(e.template, code)},
			"from":         {e.from},
		}
		req, err := http.NewRequestWithContext(ctx, http.MethodPost, e.base+"/api/message/sms/send",
			strings.NewReader(form.Encode()))
		if err != nil {
			return err
		}
		req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
		req.Header.Set("Authorization", "Bearer "+tok)
		resp, err := e.http.Do(req)
		if err != nil {
			return fmt.Errorf("eskiz send: %w", err)
		}
		body, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<16))
		resp.Body.Close()
		switch {
		case resp.StatusCode == http.StatusOK:
			return nil
		case resp.StatusCode == http.StatusUnauthorized && attempt == 0:
			lastErr = errors.New("eskiz send: token rejected")
			continue
		default:
			// The body says which template was refused, which is the usual cause.
			return fmt.Errorf("eskiz send: %d %s", resp.StatusCode, strings.TrimSpace(string(body)))
		}
	}
	return lastErr
}

// logSender is used when no provider is configured: it writes the message to the log
// instead of sending it, so local development needs no account. Never reachable in
// production, where a missing provider turns verification off entirely.
type logSender struct{ out *bytes.Buffer }

func (l *logSender) Via() string { return "sms" }

func (l *logSender) Send(_ context.Context, phone, code string) error {
	if l.out != nil {
		fmt.Fprintf(l.out, "%s %s\n", phone, code)
	}
	return nil
}
