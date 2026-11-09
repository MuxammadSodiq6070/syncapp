package main

import (
	"context"
	"crypto/rand"
	"crypto/subtle"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/url"
	"strings"
	"time"
)

const telegramBotBase = "https://api.telegram.org"

const (
	// How long the app has to finish the conversation with the bot.
	botNonceTTL = 15 * time.Minute
	// How long the issued ticket may be presented for. Short, because it is the
	// whole proof: the app reconnects with it straight away.
	botTicketTTL = 10 * time.Minute
)

var (
	errNoVerification = errors.New("no_verification")
	errBadTicket      = errors.New("invalid_ticket")
)

// BotVerifier signs people up through a Telegram bot. The bot cannot message
// somebody first, so the app sends them to it with a one-time nonce in the deep
// link; they tap Start and then the button that shares their number. Telegram is
// what vouches for the number, which is why this costs nothing: no SMS, no credit,
// no company registration.
type BotVerifier struct {
	base, token, username, secret string
	http                          *http.Client
	store                         *Store
	phoneHash                     func(string) string
}

func NewBotVerifier(token, username string, store *Store, phoneHash func(string) string) (*BotVerifier, error) {
	if token == "" {
		return nil, nil
	}
	if username == "" {
		return nil, errors.New("TELEGRAM_BOT_USERNAME is needed so the app can open the right bot")
	}
	if phoneHash == nil {
		return nil, errors.New("a bot needs SYNC_PHONE_HASH_KEY: that key is what keeps numbers out of the database")
	}
	// Telegram repeats this back on every webhook call, and it is the only thing
	// that distinguishes a real update from anyone who guesses the path.
	raw := make([]byte, 24)
	if _, err := rand.Read(raw); err != nil {
		return nil, err
	}
	return &BotVerifier{
		base:      telegramBotBase,
		token:     token,
		username:  strings.TrimPrefix(username, "@"),
		secret:    hex.EncodeToString(raw),
		http:      &http.Client{Timeout: 20 * time.Second},
		store:     store,
		phoneHash: phoneHash,
	}, nil
}

// ---- Telegram Bot API ------------------------------------------------------

type botUser struct {
	ID int64 `json:"id"`
}

type botContact struct {
	PhoneNumber string `json:"phone_number"`
	UserID      int64  `json:"user_id"`
}

type botMessage struct {
	From    *botUser    `json:"from"`
	Chat    *botUser    `json:"chat"`
	Text    string      `json:"text"`
	Contact *botContact `json:"contact"`
}

type botUpdate struct {
	Message *botMessage `json:"message"`
}

func (b *BotVerifier) call(ctx context.Context, method string, form url.Values) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodPost,
		b.base+"/bot"+b.token+"/"+method, strings.NewReader(form.Encode()))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	resp, err := b.http.Do(req)
	if err != nil {
		return fmt.Errorf("telegram bot %s: %w", method, err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<16))
	var out struct {
		OK          bool   `json:"ok"`
		Description string `json:"description"`
	}
	if json.Unmarshal(body, &out) != nil || !out.OK {
		return fmt.Errorf("telegram bot %s: %s", method, strings.TrimSpace(string(body)))
	}
	return nil
}

func (b *BotVerifier) send(ctx context.Context, chat int64, text, markup string) error {
	form := url.Values{
		"chat_id": {fmt.Sprint(chat)},
		"text":    {text},
	}
	if markup != "" {
		form.Set("reply_markup", markup)
	}
	return b.call(ctx, "sendMessage", form)
}

// SetWebhook points Telegram at this gateway. Called once at start-up: a webhook
// also means an update wakes a sleeping machine, which long polling would not.
func (b *BotVerifier) SetWebhook(ctx context.Context, publicURL string) error {
	return b.call(ctx, "setWebhook", url.Values{
		"url":             {strings.TrimSuffix(publicURL, "/") + "/bot/update"},
		"secret_token":    {b.secret},
		"allowed_updates": {`["message"]`},
	})
}

// ---- the flow --------------------------------------------------------------

func randomToken() (string, error) {
	raw := make([]byte, 16)
	if _, err := rand.Read(raw); err != nil {
		return "", err
	}
	return hex.EncodeToString(raw), nil
}

// Start opens a verification and returns the nonce and the link the app should open.
func (b *BotVerifier) Start(ctx context.Context) (nonce, link string, err error) {
	if nonce, err = randomToken(); err != nil {
		return "", "", err
	}
	if err = b.store.StartBotVerification(ctx, nonce); err != nil {
		return "", "", err
	}
	return nonce, fmt.Sprintf("https://t.me/%s?start=%s", b.username, nonce), nil
}

// Poll reports the ticket once Telegram has vouched for a number.
func (b *BotVerifier) Poll(ctx context.Context, nonce string) (string, error) {
	if len(nonce) != 32 {
		return "", errNoVerification
	}
	return b.store.PollBotTicket(ctx, nonce, time.Now().Add(-botNonceTTL).UnixMilli())
}

// Consume turns a ticket into the phone hash to register, and spends it.
func (b *BotVerifier) Consume(ctx context.Context, ticket string) (string, error) {
	if len(ticket) != 32 {
		return "", errBadTicket
	}
	return b.store.ConsumeBotTicket(ctx, ticket, time.Now().Add(-botTicketTTL).UnixMilli())
}

// HandleUpdate is the webhook. It answers Telegram quickly and never reports an
// internal problem back to it, because Telegram retries on failure and a retry of a
// contact message would not help.
func (b *BotVerifier) HandleUpdate(w http.ResponseWriter, r *http.Request) {
	given := r.Header.Get("X-Telegram-Bot-Api-Secret-Token")
	if subtle.ConstantTimeCompare([]byte(given), []byte(b.secret)) != 1 {
		http.Error(w, "forbidden", http.StatusForbidden)
		return
	}
	var up botUpdate
	if json.NewDecoder(io.LimitReader(r.Body, 1<<16)).Decode(&up) != nil {
		w.WriteHeader(http.StatusOK)
		return
	}
	w.WriteHeader(http.StatusOK)
	if up.Message == nil || up.Message.From == nil || up.Message.Chat == nil {
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	switch {
	case up.Message.Contact != nil:
		b.onContact(ctx, up.Message)
	case strings.HasPrefix(up.Message.Text, "/start"):
		b.onStart(ctx, up.Message)
	}
}

func (b *BotVerifier) onStart(ctx context.Context, m *botMessage) {
	nonce := strings.TrimSpace(strings.TrimPrefix(m.Text, "/start"))
	if len(nonce) != 32 {
		// Somebody opened the bot directly rather than from the app.
		_ = b.send(ctx, m.Chat.ID, botText("open_from_app"), "")
		return
	}
	if err := b.store.BindBotChat(ctx, nonce, m.From.ID,
		time.Now().Add(-botNonceTTL).UnixMilli()); err != nil {
		if errors.Is(err, errNoVerification) {
			_ = b.send(ctx, m.Chat.ID, botText("expired"), "")
			return
		}
		log.Printf("bot bind: %v", err)
		return
	}
	// One button, and it is Telegram that fills in the number: the person cannot
	// type someone else's, and we never see a number they have not proven.
	markup := `{"keyboard":[[{"text":"` + botText("share_button") +
		`","request_contact":true}]],"resize_keyboard":true,"one_time_keyboard":true}`
	if err := b.send(ctx, m.Chat.ID, botText("ask_number"), markup); err != nil {
		log.Printf("bot ask: %v", err)
	}
}

func (b *BotVerifier) onContact(ctx context.Context, m *botMessage) {
	// A contact card can be forwarded, so a shared number only counts when it is
	// the sender's own. Without this check anyone could sign up as anyone.
	if m.Contact.UserID == 0 || m.Contact.UserID != m.From.ID {
		_ = b.send(ctx, m.Chat.ID, botText("own_number_only"), "")
		return
	}
	phone, err := normalizePhone(m.Contact.PhoneNumber)
	if err != nil {
		_ = b.send(ctx, m.Chat.ID, botText("bad_number"), "")
		return
	}
	// A number that already has an account is not turned away: registering with it
	// takes that account over, which is how someone signs in from another phone.
	hash := b.phoneHash(phone)
	ticket, err := randomToken()
	if err != nil {
		log.Printf("bot ticket: %v", err)
		return
	}
	if err := b.store.IssueBotTicket(ctx, m.From.ID, hash, ticket,
		time.Now().Add(-botNonceTTL).UnixMilli()); err != nil {
		if errors.Is(err, errNoVerification) {
			_ = b.send(ctx, m.Chat.ID, botText("open_from_app"), "")
			return
		}
		log.Printf("bot issue: %v", err)
		return
	}
	_ = b.send(ctx, m.Chat.ID, botText("done"), `{"remove_keyboard":true}`)
}

// botText holds what the bot says. The bot has no idea which language the person
// chose in the app, so it speaks Uzbek with English underneath, and says plainly
// that it will never ask for anything else.
func botText(key string) string {
	switch key {
	case "ask_number":
		return "Sync hisobingizni ochish uchun telefon raqamingizni ulashing.\n" +
			"Pastdagi tugmani bosing — raqamni Telegram o‘zi yuboradi.\n\n" +
			"Sync sizdan boshqa hech narsa so‘ramaydi: na parol, na kod, na tiklash kaliti.\n\n" +
			"— — —\nShare your phone number to create your Sync account. " +
			"Tap the button below; Telegram sends the number itself."
	case "share_button":
		return "📱 Raqamni ulashish"
	case "done":
		return "✅ Tasdiqlandi. Ilovaga qayting — hisobingiz ochiladi.\n\n" +
			"— — —\n✅ Verified. Go back to the app."
	case "already_used":
		return "Bu raqamda allaqachon Sync hisobi bor.\n\n— — —\nThis number already has a Sync account."
	case "own_number_only":
		return "Faqat o‘zingizning raqamingizni ulashing — tugmani bosing.\n\n" +
			"— — —\nShare your own number using the button."
	case "bad_number":
		return "Raqamni o‘qib bo‘lmadi.\n\n— — —\nThat number could not be read."
	case "expired":
		return "Bu havolaning muddati tugadi. Ilovada qaytadan boshlang.\n\n" +
			"— — —\nThis link has expired. Start again in the app."
	default:
		return "Sync ilovasini oching va “Telegram orqali davom etish”ni bosing.\n\n" +
			"— — —\nOpen the Sync app and choose “Continue with Telegram”."
	}
}

// hasherFunc adapts an optional hasher, so the bot can be told plainly that the key
// is missing instead of taking a method value on a nil pointer.
func hasherFunc(h *PhoneHasher) func(string) string {
	if h == nil {
		return nil
	}
	return h.Hash
}
