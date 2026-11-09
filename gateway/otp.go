package main

import (
	"context"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"errors"
	"fmt"
	"math/big"
	"regexp"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
)

const (
	codeTTL          = 5 * time.Minute
	codeResendWait   = 60 * time.Second
	codeMaxAttempts  = 5
	codePerPhoneDay  = 5
	smsDefaultBudget = 2000
)

var (
	errBadPhone    = errors.New("invalid_phone")
	errTooSoon     = errors.New("too_soon")
	errPhoneQuota  = errors.New("phone_daily_limit")
	errSMSBudget   = errors.New("sms_budget_reached")
	errBadCode     = errors.New("invalid_code")
	errCodeExpired = errors.New("code_expired")
	errTooManyTry  = errors.New("too_many_attempts")

	phoneRe = regexp.MustCompile(`^\+[1-9][0-9]{7,14}$`)
)

// OTPService owns the whole sign-up code flow: it makes the code, decides whether a
// message may be sent at all, and later checks what the client presents. Firebase
// used to do this; doing it here means the limits, and the spending, are ours.
type OTPService struct {
	store     *Store
	sender    CodeSender
	phoneHash func(string) string
	budget    int
}

func NewOTPService(store *Store, sender CodeSender, phoneHash func(string) string, budget int) *OTPService {
	if budget <= 0 {
		budget = smsDefaultBudget
	}
	return &OTPService{store: store, sender: sender, phoneHash: phoneHash, budget: budget}
}

// Via names the provider carrying the codes, for the app's own wording.
func (o *OTPService) Via() string { return o.sender.Via() }

// normalizePhone keeps one spelling per number, so limits cannot be sidestepped by
// adding spaces or leading zeros.
func normalizePhone(raw string) (string, error) {
	var b strings.Builder
	for _, r := range raw {
		switch {
		case r >= '0' && r <= '9':
			b.WriteRune(r)
		case r == '+' && b.Len() == 0:
			b.WriteRune(r)
		case r == ' ' || r == '-' || r == '(' || r == ')':
			// Spacing people type; ignored rather than treated as a number.
		default:
			return "", errBadPhone
		}
	}
	p := b.String()
	if !strings.HasPrefix(p, "+") {
		p = "+" + p
	}
	if !phoneRe.MatchString(p) {
		return "", errBadPhone
	}
	return p, nil
}

func newCode() (string, error) {
	n, err := rand.Int(rand.Reader, big.NewInt(1000000))
	if err != nil {
		return "", err
	}
	return fmt.Sprintf("%06d", n.Int64()), nil
}

func (o *OTPService) codeHash(phone, code string) string {
	// Keyed and bound to the number, so one stolen row cannot be replayed elsewhere.
	m := hmac.New(sha256.New, []byte(o.phoneHash(phone)))
	m.Write([]byte(code))
	return hex.EncodeToString(m.Sum(nil))
}

// Request sends a code, unless a limit says otherwise. Every limit is checked in one
// transaction so parallel requests cannot slip past together.
func (o *OTPService) Request(ctx context.Context, rawPhone string) error {
	phone, err := normalizePhone(rawPhone)
	if err != nil {
		return err
	}
	// A number that already has an account still gets a code. Registering with it
	// takes the account over, which is what someone moving to another phone needs;
	// refusing here would lock them out of their own number. The daily and
	// service-wide limits below are what keep that from being a way to waste money.
	code, err := newCode()
	if err != nil {
		return err
	}
	now := time.Now()
	if err := o.store.ReserveCode(ctx, o.phoneHash(phone), o.codeHash(phone, code), now, o.budget); err != nil {
		return err
	}
	if err := o.sender.Send(ctx, phone, code); err != nil {
		// The reservation stands: a failed send must not become a way to make the
		// service try again and again at our expense. A number with no Telegram is
		// reported as such, so the person can try another one instead of waiting for
		// a code that will never come.
		if errors.Is(err, errNoTelegram) {
			return errNoTelegram
		}
		return fmt.Errorf("send code: %w", err)
	}
	return nil
}

// Check consumes one attempt and reports whether the code was right.
func (o *OTPService) Check(ctx context.Context, rawPhone, code string) (string, error) {
	phone, err := normalizePhone(rawPhone)
	if err != nil {
		return "", err
	}
	hash := o.phoneHash(phone)
	if err := o.store.CheckCode(ctx, hash, o.codeHash(phone, code), time.Now()); err != nil {
		return "", err
	}
	return hash, nil
}

// PhoneTaken reports whether a number already has an account.
func (s *Store) PhoneTaken(ctx context.Context, phoneHash string) (bool, error) {
	var n int
	err := s.db.QueryRow(ctx, `SELECT count(*) FROM sync_gateway.users WHERE phone_hash = $1`, phoneHash).Scan(&n)
	return n > 0, err
}

// ReserveCode applies the resend wait, the per-number daily cap and the service-wide
// daily budget, then stores the new code. One transaction, so nothing races.
func (s *Store) ReserveCode(ctx context.Context, phoneHash, codeHash string, now time.Time, budget int) error {
	ctx, cancel := context.WithTimeout(ctx, dbTimeout)
	defer cancel()
	day := now.Format("2006-01-02")
	return pgx.BeginFunc(ctx, s.db, func(tx pgx.Tx) error {
		var sentAt int64
		var sentDay time.Time
		var sentToday int
		err := tx.QueryRow(ctx, `SELECT sent_at, sent_day, sent_today FROM sync_gateway.signup_codes
			WHERE phone_hash = $1 FOR UPDATE`, phoneHash).Scan(&sentAt, &sentDay, &sentToday)
		switch {
		case errors.Is(err, pgx.ErrNoRows):
			sentToday = 0
		case err != nil:
			return err
		default:
			if now.Sub(time.UnixMilli(sentAt)) < codeResendWait {
				return errTooSoon
			}
			if sentDay.Format("2006-01-02") != day {
				sentToday = 0
			}
			if sentToday >= codePerPhoneDay {
				return errPhoneQuota
			}
		}
		var spent int
		if err := tx.QueryRow(ctx, `
			INSERT INTO sync_gateway.sms_budget (day, sent) VALUES ($1, 0)
			ON CONFLICT (day) DO UPDATE SET sent = sync_gateway.sms_budget.sent
			RETURNING sent`, day).Scan(&spent); err != nil {
			return err
		}
		if spent >= budget {
			return errSMSBudget
		}
		if _, err := tx.Exec(ctx, `UPDATE sync_gateway.sms_budget SET sent = sent + 1 WHERE day = $1`, day); err != nil {
			return err
		}
		_, err = tx.Exec(ctx, `
			INSERT INTO sync_gateway.signup_codes (phone_hash, code_hash, expires_at, attempts, sent_at, sent_day, sent_today)
			VALUES ($1, $2, $3, 0, $4, $5, $6)
			ON CONFLICT (phone_hash) DO UPDATE SET code_hash = $2, expires_at = $3, attempts = 0, sent_at = $4,
				sent_day = $5, sent_today = $6`,
			phoneHash, codeHash, now.Add(codeTTL).UnixMilli(), now.UnixMilli(), day, sentToday+1)
		return err
	})
}

// CheckCode spends one attempt. A wrong code is never distinguishable by timing, and
// the row is removed as soon as it is used or exhausted.
func (s *Store) CheckCode(ctx context.Context, phoneHash, codeHash string, now time.Time) error {
	ctx, cancel := context.WithTimeout(ctx, dbTimeout)
	defer cancel()
	var outcome error
	err := pgx.BeginFunc(ctx, s.db, func(tx pgx.Tx) error {
		var stored string
		var expires int64
		var attempts int
		err := tx.QueryRow(ctx, `SELECT code_hash, expires_at, attempts FROM sync_gateway.signup_codes
			WHERE phone_hash = $1 FOR UPDATE`, phoneHash).Scan(&stored, &expires, &attempts)
		if errors.Is(err, pgx.ErrNoRows) {
			outcome = errBadCode
			return nil
		}
		if err != nil {
			return err
		}
		// An empty stored hash means the code was already used. Keeping the row is
		// deliberate: it carries the resend wait and the daily count for this number.
		switch {
		case stored == "":
			outcome = errBadCode
			return nil
		case now.After(time.UnixMilli(expires)):
			outcome = errCodeExpired
		case attempts >= codeMaxAttempts:
			outcome = errTooManyTry
		case subtle.ConstantTimeCompare([]byte(stored), []byte(codeHash)) != 1:
			outcome = errBadCode
			_, err = tx.Exec(ctx, `UPDATE sync_gateway.signup_codes SET attempts = attempts + 1
				WHERE phone_hash = $1`, phoneHash)
			return err
		}
		// Used, expired or exhausted: the code is spent either way.
		_, err = tx.Exec(ctx, `UPDATE sync_gateway.signup_codes SET code_hash = '', attempts = $2
			WHERE phone_hash = $1`, phoneHash, codeMaxAttempts)
		return err
	})
	if err != nil {
		return err
	}
	return outcome
}

// SweepCodes removes rows once their daily count no longer matters. Expired codes
// are kept until then, because the row is also what limits resends for that number.
func (s *Store) SweepCodes(ctx context.Context, now time.Time) error {
	if _, err := s.db.Exec(ctx, `DELETE FROM sync_gateway.signup_codes WHERE sent_day < $1`,
		now.AddDate(0, 0, -1).Format("2006-01-02")); err != nil {
		return err
	}
	_, err := s.db.Exec(ctx, `DELETE FROM sync_gateway.sms_budget WHERE day < $1`,
		now.AddDate(0, 0, -7).Format("2006-01-02"))
	return err
}
