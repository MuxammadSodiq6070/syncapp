package main

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"time"
)

// ServiceChatID is the chat the app shows for messages from Sync itself. It is a
// reserved name, not an identity: no key can produce it, so nobody can register it
// and no peer can send into the chat that carries the verified mark.
const ServiceChatID = "service"

// serviceRetention bounds how long an undelivered notice waits for a device.
const serviceRetention = 30 * 24 * time.Hour

// ServiceMessage is one message from Sync, as the client receives it.
type ServiceMessage struct {
	ID   string         `json:"id"`
	Kind string         `json:"kind"`
	Body map[string]any `json:"body"`
	Ts   int64          `json:"ts"`
}

// QueueService stores a message from Sync for one account. It is kept until a device
// connects and takes it, so a sign-in notice is not lost while the account is offline.
func (s *Store) QueueService(ctx context.Context, userID, kind string, body map[string]any) error {
	raw, err := json.Marshal(body)
	if err != nil {
		return err
	}
	id := make([]byte, 16)
	if _, err := rand.Read(id); err != nil {
		return err
	}
	ctx, cancel := context.WithTimeout(ctx, dbTimeout)
	defer cancel()
	_, err = s.db.Exec(ctx, `
		INSERT INTO sync_gateway.service_messages (id, user_id, kind, body, created_at)
		VALUES ($1, $2, $3, $4, $5)`,
		hex.EncodeToString(id), userID, kind, string(raw), time.Now().UnixMilli())
	return err
}

// TakeService returns this account's undelivered messages and marks them delivered in
// the same statement, so two connections cannot both be handed the same notice.
func (s *Store) TakeService(ctx context.Context, userID string) ([]ServiceMessage, error) {
	ctx, cancel := context.WithTimeout(ctx, dbTimeout)
	defer cancel()
	rows, err := s.db.Query(ctx, `
		UPDATE sync_gateway.service_messages SET delivered = true
		WHERE id IN (
			SELECT id FROM sync_gateway.service_messages
			WHERE user_id = $1 AND NOT delivered
			ORDER BY created_at LIMIT 100
		)
		RETURNING id, kind, body, created_at`, userID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []ServiceMessage
	for rows.Next() {
		var m ServiceMessage
		var raw []byte
		if err := rows.Scan(&m.ID, &m.Kind, &raw, &m.Ts); err != nil {
			return nil, err
		}
		if err := json.Unmarshal(raw, &m.Body); err != nil {
			return nil, err
		}
		out = append(out, m)
	}
	return out, rows.Err()
}

// SweepService drops notices nobody came back for.
func (s *Store) SweepService(ctx context.Context) error {
	ctx, cancel := context.WithTimeout(ctx, dbTimeout)
	defer cancel()
	_, err := s.db.Exec(ctx, `DELETE FROM sync_gateway.service_messages WHERE created_at < $1`,
		time.Now().Add(-serviceRetention).UnixMilli())
	return err
}

// NoteDevice records which device this account is on and reports whether it changed.
// An empty stored value means the account has not reported one before, which is not a
// change: an existing account getting the feature for the first time is not a sign-in
// somewhere else.
func (s *Store) NoteDevice(ctx context.Context, userID, device string) (changed bool, err error) {
	if device == "" {
		return false, nil
	}
	ctx, cancel := context.WithTimeout(ctx, dbTimeout)
	defer cancel()
	var previous string
	err = s.db.QueryRow(ctx, `
		WITH prev AS (SELECT device_id FROM sync_gateway.users WHERE id = $1)
		UPDATE sync_gateway.users SET device_id = $2 WHERE id = $1
		RETURNING (SELECT device_id FROM prev)`,
		userID, device).Scan(&previous)
	if err != nil {
		return false, err
	}
	return previous != "" && previous != device, nil
}

// notifyService stores a message from Sync for an account to collect.
//
// It deliberately does not push to whatever connection happens to be registered for
// that account: during authentication the replaced connection is still registered for
// a moment, and handing it the notice would mark it delivered to a socket that is
// about to close, losing it. Every notice is raised while a connection is being set
// up, and flushService on that connection delivers it, so queueing is enough. A
// failure here must not fail the sign-in that triggered it, so it is only logged.
func (h *Hub) notifyService(ctx context.Context, userID, kind string, body map[string]any) {
	if err := h.store.QueueService(ctx, userID, kind, body); err != nil {
		log.Printf("service message: %v", err)
	}
}

// flushService hands this connection every notice waiting for its account.
func (h *Hub) flushService(ctx context.Context, c *Conn) {
	msgs, err := h.store.TakeService(ctx, c.id)
	if err != nil {
		log.Printf("take service messages: %v", err)
		return
	}
	for _, m := range msgs {
		c.sendJSON(map[string]any{
			"t": "service", "id": m.ID, "kind": m.Kind, "body": m.Body, "ts": m.Ts,
		})
	}
}

// welcomeBody is the first thing a new account sees, and it says plainly what this
// chat is for: it is the one chat the gateway itself writes to, so a message asking
// for a code or a key here would be a forgery.
func welcomeBody() map[string]any {
	return map[string]any{"text": "welcome"}
}

func signInBody(when time.Time, place string) map[string]any {
	return map[string]any{"text": "new_device", "at": when.UnixMilli(), "place": place}
}

var errReservedID = errors.New("reserved_id")

// reservedIDs can never be registered. The service chat is addressed by name rather
// than by key, so this is belt and braces: it also keeps an identity from taking a
// name the client treats as special.
var reservedIDs = map[string]bool{
	ServiceChatID: true,
	"saved":       true,
	"":            true,
}

func checkID(id string) error {
	if reservedIDs[id] {
		return fmt.Errorf("%w: %s", errReservedID, id)
	}
	return nil
}

// ---- bot sign-up -----------------------------------------------------------

// StartBotVerification opens a verification the app can poll for.
func (s *Store) StartBotVerification(ctx context.Context, nonce string) error {
	ctx, cancel := context.WithTimeout(ctx, dbTimeout)
	defer cancel()
	_, err := s.db.Exec(ctx, `
		INSERT INTO sync_gateway.bot_verifications (nonce, created_at) VALUES ($1, $2)`,
		nonce, time.Now().UnixMilli())
	return err
}

// BindBotChat records which Telegram account opened the link. The nonce must still
// be fresh and unspent, which is what keeps an old link from being reused.
func (s *Store) BindBotChat(ctx context.Context, nonce string, telegramID, notBefore int64) error {
	ctx, cancel := context.WithTimeout(ctx, dbTimeout)
	defer cancel()
	tag, err := s.db.Exec(ctx, `
		UPDATE sync_gateway.bot_verifications SET telegram_id = $2
		WHERE nonce = $1 AND NOT consumed AND ticket IS NULL AND created_at >= $3`,
		nonce, telegramID, notBefore)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return errNoVerification
	}
	return nil
}

// IssueBotTicket attaches the proven number to the newest link this Telegram account
// opened, and returns the ticket the app will present.
func (s *Store) IssueBotTicket(ctx context.Context, telegramID int64, phoneHash, ticket string, notBefore int64) error {
	ctx, cancel := context.WithTimeout(ctx, dbTimeout)
	defer cancel()
	tag, err := s.db.Exec(ctx, `
		UPDATE sync_gateway.bot_verifications SET phone_hash = $2, ticket = $3, created_at = $5
		WHERE nonce = (
			SELECT nonce FROM sync_gateway.bot_verifications
			WHERE telegram_id = $1 AND NOT consumed AND ticket IS NULL AND created_at >= $4
			ORDER BY created_at DESC LIMIT 1
		)`,
		telegramID, phoneHash, ticket, notBefore, time.Now().UnixMilli())
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return errNoVerification
	}
	return nil
}

// PollBotTicket hands the app its ticket once the bot has one, and nothing before.
func (s *Store) PollBotTicket(ctx context.Context, nonce string, notBefore int64) (string, error) {
	ctx, cancel := context.WithTimeout(ctx, dbTimeout)
	defer cancel()
	var ticket *string
	err := s.db.QueryRow(ctx, `
		SELECT ticket FROM sync_gateway.bot_verifications
		WHERE nonce = $1 AND NOT consumed AND created_at >= $2`, nonce, notBefore).Scan(&ticket)
	if err != nil || ticket == nil {
		return "", errNoVerification
	}
	return *ticket, nil
}

// ConsumeBotTicket spends a ticket and returns the number's hash. Marking it spent in
// the same statement is what makes it single use: two connections racing with the
// same ticket cannot both register.
func (s *Store) ConsumeBotTicket(ctx context.Context, ticket string, notBefore int64) (string, error) {
	ctx, cancel := context.WithTimeout(ctx, dbTimeout)
	defer cancel()
	var phoneHash *string
	err := s.db.QueryRow(ctx, `
		UPDATE sync_gateway.bot_verifications SET consumed = true
		WHERE ticket = $1 AND NOT consumed AND created_at >= $2
		RETURNING phone_hash`, ticket, notBefore).Scan(&phoneHash)
	if err != nil || phoneHash == nil || *phoneHash == "" {
		return "", errBadTicket
	}
	return *phoneHash, nil
}

// SweepBotVerifications drops links nobody finished.
func (s *Store) SweepBotVerifications(ctx context.Context) error {
	ctx, cancel := context.WithTimeout(ctx, dbTimeout)
	defer cancel()
	_, err := s.db.Exec(ctx, `DELETE FROM sync_gateway.bot_verifications WHERE created_at < $1`,
		time.Now().Add(-botNonceTTL-botTicketTTL).UnixMilli())
	return err
}
