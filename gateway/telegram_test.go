package main

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"testing"
)

// telegramStub answers the two Gateway calls and records what it was asked.
type telegramStub struct {
	calls     []string
	auth      string
	sentCode  string
	sentReqID string
	sentTTL   string
	ableOK    bool
	ableError string
	sendOK    bool
	sendError string
}

func (s *telegramStub) server(t *testing.T) *httptest.Server {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if err := r.ParseForm(); err != nil {
			t.Error(err)
		}
		s.calls = append(s.calls, r.URL.Path)
		s.auth = r.Header.Get("Authorization")
		switch r.URL.Path {
		case "/checkSendAbility":
			if s.ableOK {
				fmt.Fprint(w, `{"ok":true,"result":{"request_id":"req-1","request_cost":0.01}}`)
				return
			}
			fmt.Fprintf(w, `{"ok":false,"error":%q}`, s.ableError)
		case "/sendVerificationMessage":
			s.sentCode = r.FormValue("code")
			s.sentReqID = r.FormValue("request_id")
			s.sentTTL = r.FormValue("ttl")
			if s.sendOK {
				fmt.Fprint(w, `{"ok":true,"result":{"request_id":"req-1","request_cost":0}}`)
				return
			}
			fmt.Fprintf(w, `{"ok":false,"error":%q}`, s.sendError)
		default:
			t.Errorf("unexpected call to %s", r.URL.Path)
		}
	}))
	t.Cleanup(srv.Close)
	return srv
}

func TestTelegramSenderDeliversOneChargeableCode(t *testing.T) {
	stub := &telegramStub{ableOK: true, sendOK: true}
	srv := stub.server(t)
	s := NewTelegramSender("tok")
	s.base = srv.URL
	if err := s.Send(context.Background(), "+998901234567", "123456"); err != nil {
		t.Fatal(err)
	}
	// The ability check must come first: it is what makes the send itself free, and
	// what keeps a number with no Telegram from costing anything.
	want := []string{"/checkSendAbility", "/sendVerificationMessage"}
	if fmt.Sprint(stub.calls) != fmt.Sprint(want) {
		t.Fatalf("calls %v, want %v", stub.calls, want)
	}
	if stub.sentReqID != "req-1" {
		t.Fatalf("the request_id was not carried over, so the send was charged twice: %q", stub.sentReqID)
	}
	if stub.sentCode != "123456" {
		t.Fatalf("code %q", stub.sentCode)
	}
	if stub.sentTTL != "300" {
		t.Fatalf("ttl %q, want the code's own five minutes", stub.sentTTL)
	}
	if stub.auth != "Bearer tok" {
		t.Fatalf("auth %q", stub.auth)
	}
}

func TestTelegramSenderReportsANumberWithoutTelegram(t *testing.T) {
	stub := &telegramStub{ableError: "SEND_ABILITY_CHECK_FAILED"}
	srv := stub.server(t)
	s := NewTelegramSender("tok")
	s.base = srv.URL
	err := s.Send(context.Background(), "+998901234567", "123456")
	if !errors.Is(err, errNoTelegram) {
		t.Fatalf("want errNoTelegram, got %v", err)
	}
	// Nothing may be sent, or charged, for a number that cannot receive.
	if len(stub.calls) != 1 {
		t.Fatalf("calls %v: a message was sent anyway", stub.calls)
	}
}

// Our own misconfiguration must never be reported to the person as a problem with
// their phone number: an empty balance or a bad token belongs in the log.
func TestTelegramSenderDoesNotBlameTheNumberForOurFaults(t *testing.T) {
	for _, reason := range []string{"ACCESS_TOKEN_INVALID", "BALANCE_NOT_ENOUGH", "FLOOD_WAIT_60", ""} {
		stub := &telegramStub{ableError: reason}
		srv := stub.server(t)
		s := NewTelegramSender("tok")
		s.base = srv.URL
		err := s.Send(context.Background(), "+998901234567", "123456")
		if err == nil {
			t.Fatalf("%s: expected an error", reason)
		}
		if errors.Is(err, errNoTelegram) {
			t.Fatalf("%s was reported as the number having no Telegram", reason)
		}
	}
}

func TestTelegramSenderSurfacesASendRefusal(t *testing.T) {
	stub := &telegramStub{ableOK: true, sendError: "PHONE_NUMBER_NOT_FOUND"}
	srv := stub.server(t)
	s := NewTelegramSender("tok")
	s.base = srv.URL
	if err := s.Send(context.Background(), "+998901234567", "123456"); !errors.Is(err, errNoTelegram) {
		t.Fatalf("want errNoTelegram, got %v", err)
	}
}

// A number with no Telegram must reach the client as that, not as a generic failure,
// so the app can tell the person to try another number.
func TestRequestPassesNoTelegramThrough(t *testing.T) {
	otp, rec, _ := newOTP(t)
	rec.fail = fmt.Errorf("telegram checkSendAbility: %w", errNoTelegram)
	if err := otp.Request(context.Background(), "+998905550007"); !errors.Is(err, errNoTelegram) {
		t.Fatalf("want errNoTelegram, got %v", err)
	}
}
