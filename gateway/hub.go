package main

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	_ "embed"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"log"
	"net"
	"net/http"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"
	"unicode/utf8"

	"github.com/gorilla/websocket"
)

const (
	writeWait       = 10 * time.Second
	pongWait        = 70 * time.Second
	pingEvery       = 30 * time.Second
	authWait        = 10 * time.Second
	preAuthFrame    = 4 * 1024
	maxFrameBytes   = 1024 * 1024
	maxTransient    = 4 * 1024
	sendBuffer      = 256
	transientRoom   = sendBuffer / 2 // transient traffic can only ever use half the buffer
	deliverBatch    = 100
	ratePerSecond   = 100.0
	rateBurst       = 300.0
	bytesPerToken   = 64 * 1024
	maxConnsPerIP   = 64
	maxNewIDsPerIP  = 100
	newIDWindow     = time.Hour
	transferTimeout = 10 * time.Minute
)

// Served at /privacy so the app and the app stores have a stable public URL.
// Source of truth for this text: gateway/static/privacy.html.
//
//go:embed static/privacy.html
var privacyHTML []byte

var usernameRe = regexp.MustCompile(`^[A-Za-z0-9_]{3,32}$`)

// Rate buckets per identity, so a reconnect does not refill them.
type bucket struct {
	tokens float64
	last   time.Time
}

type limiter struct {
	mu      sync.Mutex
	buckets map[string]*bucket
}

func (l *limiter) allow(id string, cost float64, now time.Time) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	b := l.buckets[id]
	if b == nil {
		b = &bucket{tokens: rateBurst, last: now}
		l.buckets[id] = b
		if len(l.buckets) > 200000 { // memory bound; only idle, full buckets are dropped
			for k, v := range l.buckets {
				if now.Sub(v.last) > time.Duration(rateBurst/ratePerSecond*float64(time.Second)) {
					delete(l.buckets, k)
				}
			}
		}
	}
	b.tokens += now.Sub(b.last).Seconds() * ratePerSecond
	if b.tokens > rateBurst {
		b.tokens = rateBurst
	}
	b.last = now
	if b.tokens < cost {
		return false
	}
	b.tokens -= cost
	return true
}

// Per-address limits. Identities are free, so an address is the only thing that costs
// an attacker anything to change.
type ipLimits struct {
	mu     sync.Mutex
	conns  map[string]int
	newIDs map[string][]time.Time
}

func (l *ipLimits) acquire(ip string) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.conns[ip] >= maxConnsPerIP {
		return false
	}
	l.conns[ip]++
	return true
}

func (l *ipLimits) release(ip string) {
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.conns[ip]--; l.conns[ip] <= 0 {
		delete(l.conns, ip)
	}
}

func (l *ipLimits) noteNewID(ip string, now time.Time) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	kept := l.newIDs[ip][:0]
	for _, t := range l.newIDs[ip] {
		if now.Sub(t) < newIDWindow {
			kept = append(kept, t)
		}
	}
	if len(kept) >= maxNewIDsPerIP {
		l.newIDs[ip] = kept
		return false
	}
	l.newIDs[ip] = append(kept, now)
	return true
}

type Hub struct {
	store    *Store
	media    *MediaStore
	ai       *AIService
	verifier *Verifier
	otp      *OTPService
	bot      *BotVerifier
	up       websocket.Upgrader

	// IPHeader names the header a trusted proxy puts the client address in. Empty
	// means no proxy: anyone can forge a header, so it is ignored unless configured.
	IPHeader string

	rate limiter
	ips  ipLimits

	mu       sync.RWMutex
	conns    map[string]*Conn
	watchers map[string]map[*Conn]struct{}
}

func NewHub(store *Store, media *MediaStore) *Hub {
	return &Hub{
		store:    store,
		media:    media,
		ai:       NewAIService(),
		up:       websocket.Upgrader{ReadBufferSize: 16 * 1024, WriteBufferSize: 16 * 1024},
		rate:     limiter{buckets: map[string]*bucket{}},
		ips:      ipLimits{conns: map[string]int{}, newIDs: map[string][]time.Time{}},
		conns:    map[string]*Conn{},
		watchers: map[string]map[*Conn]struct{}{},
	}
}

func (h *Hub) Routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) { w.Write([]byte("ok")) })
	mux.HandleFunc("GET /privacy", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		w.Header().Set("Cache-Control", "public, max-age=3600")
		w.Write(privacyHTML)
	})
	mux.HandleFunc("GET /ws", h.serveWS)
	mux.HandleFunc("POST /verify/request", h.requestCode)
	mux.HandleFunc("POST /verify/start", h.startBotVerify)
	mux.HandleFunc("POST /verify/poll", h.pollBotVerify)
	mux.HandleFunc("POST /bot/update", h.botUpdate)
	mux.HandleFunc("POST /media", h.uploadMedia)
	mux.HandleFunc("GET /media/{id}", h.downloadMedia)
	return mux
}

func (h *Hub) clientIP(r *http.Request) string {
	if h.IPHeader != "" {
		if v := strings.TrimSpace(r.Header.Get(h.IPHeader)); v != "" {
			// The last entry is the one the trusted proxy itself appended.
			parts := strings.Split(v, ",")
			return strings.TrimSpace(parts[len(parts)-1])
		}
	}
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return r.RemoteAddr
	}
	return host
}

func setTransferDeadline(w http.ResponseWriter) {
	rc := http.NewResponseController(w)
	deadline := time.Now().Add(transferTimeout)
	_ = rc.SetReadDeadline(deadline)
	_ = rc.SetWriteDeadline(deadline)
}

func (h *Hub) uploadMedia(w http.ResponseWriter, r *http.Request) {
	token := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
	owner, ok := h.media.CheckToken(token)
	if !ok {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}
	setTransferDeadline(w)
	id, err := h.media.Save(r.Context(), owner, http.MaxBytesReader(w, r.Body, maxMediaBytes+1))
	var mbe *http.MaxBytesError
	switch {
	case err == nil:
	case errors.Is(err, errMediaTooLarge), errors.Is(err, errMediaQuota), errors.As(err, &mbe):
		http.Error(w, "too large", http.StatusRequestEntityTooLarge)
		return
	case errors.Is(err, errMediaEmpty):
		http.Error(w, "empty", http.StatusBadRequest)
		return
	default:
		log.Printf("media save: %v", err)
		http.Error(w, "storage error", http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]string{"id": id})
}

func (h *Hub) downloadMedia(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	if !validMediaID(id) {
		http.NotFound(w, r)
		return
	}
	setTransferDeadline(w)
	body, size, err := h.media.blobs.Get(r.Context(), id)
	if errors.Is(err, errBlobNotFound) {
		http.NotFound(w, r)
		return
	}
	if err != nil {
		log.Printf("media get: %v", err)
		http.Error(w, "storage error", http.StatusBadGateway)
		return
	}
	defer body.Close()
	w.Header().Set("Content-Type", "application/octet-stream")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	if size >= 0 {
		w.Header().Set("Content-Length", strconv.FormatInt(size, 10))
	}
	_, _ = io.Copy(w, body)
}

// CloseAll drops every connection so shutdown does not wait on hijacked sockets.
func (h *Hub) CloseAll() {
	h.mu.RLock()
	defer h.mu.RUnlock()
	for _, c := range h.conns {
		c.ws.Close()
	}
}

// SweepLoop removes what has outlived its retention period.
func (h *Hub) SweepLoop(ctx context.Context) {
	t := time.NewTicker(time.Hour)
	defer t.Stop()
	for {
		if n, err := h.store.SweepQueue(time.Now()); err != nil && ctx.Err() == nil {
			log.Printf("queue sweep: %v", err)
		} else if n > 0 {
			log.Printf("queue sweep removed %d expired envelopes", n)
		}
		if err := h.store.SweepListings(ctx, time.Now()); err != nil && ctx.Err() == nil {
			log.Printf("market sweep: %v", err)
		}
		if err := h.store.SweepCodes(ctx, time.Now()); err != nil && ctx.Err() == nil {
			log.Printf("code sweep: %v", err)
		}
		if err := h.store.SweepService(ctx); err != nil && ctx.Err() == nil {
			log.Printf("service sweep: %v", err)
		}
		if err := h.store.SweepBotVerifications(ctx); err != nil && ctx.Err() == nil {
			log.Printf("bot verification sweep: %v", err)
		}
		select {
		case <-ctx.Done():
			return
		case <-t.C:
		}
	}
}

// Conn is one authenticated device. All socket writes go through writePump.
type Conn struct {
	hub  *Hub
	ws   *websocket.Conn
	ip   string
	out  chan []byte
	done chan struct{}
	once sync.Once
	wake chan struct{}
	id   string

	// Which install this is, as the client reported it. Used once, after the
	// connection is registered, to notice a sign-in from somewhere else.
	device string

	ctx    context.Context
	cancel context.CancelFunc

	watched map[string]struct{} // guarded by hub.mu
}

func (c *Conn) close() {
	// Shutdown must never panic, whichever path reaches it first.
	c.once.Do(func() {
		close(c.done)
		if c.cancel != nil {
			c.cancel()
		}
		if c.ws != nil {
			c.ws.Close()
		}
	})
}

// sendJSON is for replies and the connection's own traffic. A client too slow to take
// them is cut off, and only that client's own requests can cause this.
func (c *Conn) sendJSON(v any) {
	raw, err := marshalFrame(v)
	if err != nil {
		log.Printf("marshal: %v", err)
		return
	}
	select {
	case c.out <- raw:
	case <-c.done:
	default:
		c.close()
	}
}

// sendBestEffort is for traffic other people cause. It is dropped rather than queued
// when the client is behind, so a stranger can never get someone disconnected.
func (c *Conn) sendBestEffort(v any) {
	if len(c.out) >= transientRoom {
		return
	}
	raw, err := marshalFrame(v)
	if err != nil {
		return
	}
	select {
	case c.out <- raw:
	default:
	}
}

func (c *Conn) writePump() {
	t := time.NewTicker(pingEvery)
	defer t.Stop()
	defer c.close()
	for {
		select {
		case <-c.done:
			return
		case m := <-c.out:
			c.ws.SetWriteDeadline(time.Now().Add(writeWait))
			if err := c.ws.WriteMessage(websocket.TextMessage, m); err != nil {
				return
			}
		case <-t.C:
			c.ws.SetWriteDeadline(time.Now().Add(writeWait))
			if err := c.ws.WriteMessage(websocket.PingMessage, nil); err != nil {
				return
			}
		}
	}
}

type inFrame struct {
	T           string   `json:"t"`
	Rid         string   `json:"rid"`
	ID          string   `json:"id"`
	BoxPK       string   `json:"box_pk"`
	BoxSig      string   `json:"box_sig"`
	Sig         string   `json:"sig"`
	To          string   `json:"to"`
	Blob        string   `json:"blob"`
	Transient   bool     `json:"transient"`
	Seq         int64    `json:"seq"`
	Q           string   `json:"q"`
	Username    string   `json:"username"`
	DisplayName string   `json:"display_name"`
	IDs         []string `json:"ids"`
	Device      string   `json:"device"`
	Ticket      string   `json:"ticket"`
	FbToken     string   `json:"fb_token"`
	Phone       string   `json:"phone"`
	Code        string   `json:"code"`
	Turns       []AITurn `json:"turns"`
	System      string   `json:"system"`
	Title       string   `json:"title"`
	Price       string   `json:"price"`
	Description string   `json:"description"`
	Category    string   `json:"category"`
}

// frameCost makes requests that do more work cost more of the identity's budget.
func frameCost(t string) float64 {
	switch t {
	case "search":
		return 10
	case "market_list", "market_post", "market_delete":
		return 20
	case "watch":
		return 20
	case "media_token", "ai":
		return 5
	}
	return 1
}

func validUserID(id string) bool {
	if len(id) != 64 || id != strings.ToLower(id) {
		return false
	}
	_, err := hex.DecodeString(id)
	return err == nil
}

// Envelopes are opaque, but always base64. Refusing anything else keeps stored size
// predictable and stops the relay being used to store arbitrary text.
func validBlob(s string) bool {
	if s == "" || len(s)%4 != 0 {
		return false
	}
	for i := 0; i < len(s); i++ {
		c := s[i]
		ok := c >= 'A' && c <= 'Z' || c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || c == '+' || c == '/' || (c == '=' && i >= len(s)-2)
		if !ok {
			return false
		}
	}
	return true
}

// verifyAuth checks the identity key signed this connection's nonce and its box key.
func verifyAuth(nonce []byte, f *inFrame) bool {
	if !validUserID(f.ID) {
		return false
	}
	pk, err1 := hex.DecodeString(f.ID)
	sig, err2 := hex.DecodeString(f.Sig)
	boxPK, err3 := hex.DecodeString(f.BoxPK)
	boxSig, err4 := hex.DecodeString(f.BoxSig)
	if err1 != nil || err2 != nil || err3 != nil || err4 != nil ||
		len(sig) != ed25519.SignatureSize || len(boxPK) != 32 || len(boxSig) != ed25519.SignatureSize {
		return false
	}
	return ed25519.Verify(pk, append([]byte("sync-auth-v1"), nonce...), sig) &&
		ed25519.Verify(pk, append([]byte("sync-box-binding-v1"), boxPK...), boxSig)
}

func (h *Hub) serveWS(w http.ResponseWriter, r *http.Request) {
	ip := h.clientIP(r)
	if !h.ips.acquire(ip) {
		http.Error(w, "too many connections", http.StatusTooManyRequests)
		return
	}
	defer h.ips.release(ip)
	ws, err := h.up.Upgrade(w, r, nil)
	if err != nil {
		return
	}
	ws.SetReadLimit(preAuthFrame)
	ctx, cancel := context.WithCancel(context.Background())
	c := &Conn{
		hub: h, ws: ws, ip: ip,
		out:     make(chan []byte, sendBuffer),
		done:    make(chan struct{}),
		wake:    make(chan struct{}, 1),
		watched: map[string]struct{}{},
		ctx:     ctx, cancel: cancel,
	}
	go c.writePump()
	defer c.close()

	if !h.authenticate(c) {
		return
	}
	ws.SetReadLimit(maxFrameBytes)
	ws.SetReadDeadline(time.Now().Add(pongWait))
	ws.SetPongHandler(func(string) error {
		return ws.SetReadDeadline(time.Now().Add(pongWait))
	})
	h.register(c)
	defer h.unregister(c)
	h.afterRegister(c)
	go c.deliverLoop()

	for {
		_, raw, err := ws.ReadMessage()
		if err != nil {
			return
		}
		ws.SetReadDeadline(time.Now().Add(pongWait))
		// Charged before parsing, by size, so an over-limit sender costs almost nothing.
		if !h.rate.allow(c.id, 1+float64(len(raw))/bytesPerToken, time.Now()) {
			var hdr struct {
				Rid string `json:"rid"`
			}
			if len(raw) < 4096 {
				_ = json.Unmarshal(raw, &hdr)
			}
			c.reply(&inFrame{Rid: hdr.Rid}, map[string]any{"ok": false, "error": "rate_limited"})
			continue
		}
		var f inFrame
		if json.Unmarshal(raw, &f) != nil {
			continue
		}
		if cost := frameCost(f.T); cost > 1 && !h.rate.allow(c.id, cost, time.Now()) {
			c.reply(&f, map[string]any{"ok": false, "error": "rate_limited"})
			continue
		}
		c.handle(&f)
	}
}

func (h *Hub) authenticate(c *Conn) bool {
	nonce := make([]byte, 32)
	if _, err := rand.Read(nonce); err != nil {
		return false
	}
	c.sendJSON(map[string]any{"t": "challenge", "nonce": hex.EncodeToString(nonce)})
	c.ws.SetReadDeadline(time.Now().Add(authWait))
	var f inFrame
	if err := c.ws.ReadJSON(&f); err != nil || f.T != "auth" || !verifyAuth(nonce, &f) {
		return false
	}
	if err := checkID(f.ID); err != nil {
		log.Printf("auth: %v", err)
		return false
	}
	u, err := h.store.Identity(f.ID)
	if err != nil {
		log.Printf("identity lookup: %v", err)
		return false
	}
	if u != nil {
		// Known identity: the signed challenge is the whole proof. Restoring an
		// account from its recovery key therefore needs no second SMS.
		if u, err = h.store.RefreshIdentity(f.ID, f.BoxPK, f.BoxSig); err != nil || u == nil {
			log.Printf("refresh identity: %v", err)
			return false
		}
	} else {
		if !h.ips.noteNewID(c.ip, time.Now()) {
			c.authError("too_many_signups")
			return false
		}
		if u, err = h.registerNew(c, &f); u == nil {
			return false
		}
	}
	c.id = f.ID
	c.device = f.Device
	c.sendJSON(map[string]any{"t": "ready", "profile": u, "server_time": time.Now().UnixMilli()})
	return true
}

// afterRegister does the work that needs the connection to be registered already.
// It must not run inside authenticate: that would put two database round trips
// between "ready" and the connection being reachable, and anything sent to this
// account in that gap would be dropped.
func (h *Hub) afterRegister(c *Conn) {
	ctx, cancel := context.WithTimeout(c.ctx, dbTimeout)
	defer cancel()
	// A device this account has not used before means someone signed in elsewhere,
	// which is exactly what the service chat exists to report. Whichever device
	// connects next is told, so the rightful owner hears about a stranger's sign-in
	// the next time they come back.
	if changed, err := h.store.NoteDevice(ctx, c.id, c.device); err != nil {
		log.Printf("note device: %v", err)
	} else if changed {
		h.notifyService(ctx, c.id, "security", signInBody(time.Now(), c.ip))
	}
	h.flushService(ctx, c)
}

// authError tells the client why it was turned away, so the app can ask for an SMS
// code instead of retrying forever. The connection closes straight after.
func (c *Conn) authError(reason string) {
	c.sendJSON(map[string]any{"t": "auth_error", "reason": reason})
	time.Sleep(50 * time.Millisecond) // let writePump flush before close
}

// registerNew creates an identity. With a verifier configured it first requires a
// Firebase ID token proving a phone number, and binds that number to this account.
func (h *Hub) registerNew(c *Conn, f *inFrame) (*User, error) {
	phoneHash := ""
	switch {
	case h.bot != nil:
		if f.Ticket == "" {
			c.authError(errNoToken.Error())
			return nil, errNoToken
		}
		ctx, cancel := context.WithTimeout(c.ctx, 15*time.Second)
		hash, err := h.bot.Consume(ctx, f.Ticket)
		cancel()
		if err != nil {
			c.authError(errBadTicket.Error())
			return nil, err
		}
		phoneHash = hash
	case h.otp != nil:
		if f.Phone == "" || f.Code == "" {
			c.authError(errNoToken.Error())
			return nil, errNoToken
		}
		ctx, cancel := context.WithTimeout(c.ctx, 15*time.Second)
		hash, err := h.otp.Check(ctx, f.Phone, f.Code)
		cancel()
		if err != nil {
			c.authError(err.Error())
			return nil, err
		}
		phoneHash = hash
	case h.verifier != nil:
		if f.FbToken == "" {
			c.authError(errNoToken.Error())
			return nil, errNoToken
		}
		ctx, cancel := context.WithTimeout(c.ctx, 15*time.Second)
		phone, err := h.verifier.VerifyPhone(ctx, f.FbToken)
		cancel()
		if err != nil {
			if errors.Is(err, errVerifierDown) {
				log.Printf("verifier unavailable: %v", err)
			}
			c.authError(err.Error())
			return nil, err
		}
		phoneHash = h.verifier.PhoneHash(phone)
	}
	u, err := h.store.Register(f.ID, f.BoxPK, f.BoxSig, phoneHash)
	if err != nil {
		if errors.Is(err, errPhoneInUse) {
			c.authError(errPhoneInUse.Error())
			return nil, err
		}
		log.Printf("register: %v", err)
		return nil, err
	}
	// The first thing a new account sees, and the chat's own introduction: this is
	// the one chat Sync itself writes to.
	wctx, cancel := context.WithTimeout(c.ctx, dbTimeout)
	defer cancel()
	h.notifyService(wctx, f.ID, "welcome", welcomeBody())
	return u, nil
}

func (h *Hub) register(c *Conn) {
	h.mu.Lock()
	old := h.conns[c.id]
	h.conns[c.id] = c
	h.mu.Unlock()
	if old != nil {
		old.close() // one active connection per identity; the newest wins
	} else {
		h.notifyPresence(c.id, true, 0)
	}
}

func (h *Hub) unregister(c *Conn) {
	h.mu.Lock()
	current := h.conns[c.id] == c
	if current {
		delete(h.conns, c.id)
	}
	for id := range c.watched {
		if set := h.watchers[id]; set != nil {
			delete(set, c)
			if len(set) == 0 {
				delete(h.watchers, id)
			}
		}
	}
	h.mu.Unlock()
	if current {
		ts := time.Now().UnixMilli()
		h.store.SetLastSeen(c.id, ts)
		h.notifyPresence(c.id, false, ts)
	}
}

func (h *Hub) notifyPresence(id string, online bool, lastSeen int64) {
	msg := map[string]any{"t": "presence", "id": id, "online": online, "last_seen": lastSeen}
	h.mu.RLock()
	defer h.mu.RUnlock()
	for w := range h.watchers[id] {
		w.sendBestEffort(msg)
	}
}

func (c *Conn) reply(f *inFrame, body map[string]any) {
	if f.Rid == "" {
		return
	}
	body["t"] = "res"
	body["rid"] = f.Rid
	c.sendJSON(body)
}

func (c *Conn) handle(f *inFrame) {
	h := c.hub
	switch f.T {
	case "send":
		c.handleSend(f)
	case "ack":
		if err := h.store.Ack(c.id, f.Seq); err != nil {
			log.Printf("ack: %v", err)
		}
	case "profile":
		c.handleProfile(f)
	case "search":
		users, err := h.store.SearchUsers(f.Q)
		if err != nil {
			log.Printf("search: %v", err)
			c.reply(f, map[string]any{"ok": false, "error": "server_error"})
			return
		}
		c.reply(f, map[string]any{"ok": true, "users": users})
	case "user":
		u, err := h.store.User(f.ID)
		if err != nil || u == nil {
			c.reply(f, map[string]any{"ok": false, "error": "unknown_user"})
			return
		}
		c.reply(f, map[string]any{"ok": true, "user": u})
	case "watch":
		c.handleWatch(f)
	case "unwatch":
		c.handleUnwatch(f)
	case "media_token":
		c.reply(f, map[string]any{"ok": true, "token": h.media.Token(c.id)})
	case "ai":
		c.handleAI(f)
	case "market_list", "market_post", "market_delete":
		c.handleMarket(f)
	default:
		c.reply(f, map[string]any{"ok": false, "error": "unknown_request"})
	}
}

func (c *Conn) handleProfile(f *inFrame) {
	name := strings.TrimSpace(f.DisplayName)
	if !usernameRe.MatchString(f.Username) {
		c.reply(f, map[string]any{"ok": false, "error": "invalid_username"})
		return
	}
	if name == "" || utf8.RuneCountInString(name) > 64 {
		c.reply(f, map[string]any{"ok": false, "error": "invalid_name"})
		return
	}
	if err := c.hub.store.SetProfile(c.id, f.Username, name); err != nil {
		if errors.Is(err, ErrUsernameTaken) {
			c.reply(f, map[string]any{"ok": false, "error": err.Error()})
			return
		}
		log.Printf("set profile: %v", err)
		c.reply(f, map[string]any{"ok": false, "error": "server_error"})
		return
	}
	c.reply(f, map[string]any{"ok": true})
}

// subscribe links watcher to target. Caller holds h.mu.
func (h *Hub) subscribe(watcher *Conn, target string) {
	watcher.watched[target] = struct{}{}
	if h.watchers[target] == nil {
		h.watchers[target] = map[*Conn]struct{}{}
	}
	h.watchers[target][watcher] = struct{}{}
}

// handleWatch records interest. Status flows only when both people ask about each
// other, so nothing reaches a stranger, and each side learns when the other has asked.
func (c *Conn) handleWatch(f *inFrame) {
	h := c.hub
	ids := make([]string, 0, len(f.IDs))
	for _, id := range f.IDs {
		if validUserID(id) && id != c.id {
			ids = append(ids, id)
		}
	}
	mutual, err := h.store.Watch(c.id, ids)
	if err != nil {
		log.Printf("watch: %v", err)
		return
	}
	type status struct {
		id     string
		online bool
	}
	var statuses []status
	h.mu.Lock()
	for _, id := range mutual {
		h.subscribe(c, id)
		other := h.conns[id]
		if other != nil {
			h.subscribe(other, c.id)
			other.sendBestEffort(map[string]any{"t": "presence", "id": c.id, "online": true, "last_seen": 0})
		}
		statuses = append(statuses, status{id, other != nil})
	}
	h.mu.Unlock()
	for _, s := range statuses {
		var last int64
		if !s.online {
			last = h.store.LastSeen(s.id)
		}
		c.sendJSON(map[string]any{"t": "presence", "id": s.id, "online": s.online, "last_seen": last})
	}
}

func (c *Conn) handleUnwatch(f *inFrame) {
	h := c.hub
	ids := make([]string, 0, len(f.IDs))
	for _, id := range f.IDs {
		if validUserID(id) {
			ids = append(ids, id)
		}
	}
	if err := h.store.Unwatch(c.id, ids); err != nil {
		log.Printf("unwatch: %v", err)
		return
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	for _, id := range ids {
		delete(c.watched, id)
		if set := h.watchers[id]; set != nil {
			delete(set, c)
		}
		// The other side stops hearing about this person too.
		if other := h.conns[id]; other != nil {
			delete(other.watched, c.id)
			if set := h.watchers[c.id]; set != nil {
				delete(set, other)
			}
		}
	}
}

func (c *Conn) handleSend(f *inFrame) {
	h := c.hub
	if !validUserID(f.To) || !validBlob(f.Blob) {
		c.reply(f, map[string]any{"ok": false, "error": "bad_request"})
		return
	}
	recipient, err := h.store.User(f.To)
	if err != nil {
		log.Printf("lookup: %v", err)
		c.reply(f, map[string]any{"ok": false, "error": "server_error"})
		return
	}
	if recipient == nil {
		c.reply(f, map[string]any{"ok": false, "error": "unknown_user"})
		return
	}

	if f.Transient {
		if len(f.Blob) > maxTransient {
			c.reply(f, map[string]any{"ok": false, "error": "bad_request"})
			return
		}
		h.mu.RLock()
		target := h.conns[f.To]
		h.mu.RUnlock()
		if target != nil {
			if sender, err := h.store.User(c.id); err == nil && sender != nil {
				target.sendBestEffort(map[string]any{"t": "transient", "from": c.id, "blob": f.Blob, "sender": sender})
			}
		}
		c.reply(f, map[string]any{"ok": true})
		return
	}
	if err := h.store.Enqueue(f.To, c.id, f.Blob); err != nil {
		if errors.Is(err, ErrQueueFull) {
			c.reply(f, map[string]any{"ok": false, "error": err.Error()})
			return
		}
		log.Printf("enqueue: %v", err)
		c.reply(f, map[string]any{"ok": false, "error": "server_error"})
		return
	}
	// Looked up after the commit: a recipient connecting before this point reads the
	// row itself, and one connecting after it is the connection woken here.
	h.mu.RLock()
	target := h.conns[f.To]
	h.mu.RUnlock()
	if target != nil {
		target.notify()
	}
	c.reply(f, map[string]any{"ok": true})
}

func (c *Conn) notify() {
	select {
	case c.wake <- struct{}{}:
	default:
	}
}

// deliverLoop streams the queue in order. Rows stay stored until the client acks,
// so a dropped connection redelivers them on the next one.
func (c *Conn) deliverLoop() {
	h := c.hub
	var after int64
	for {
		batch, err := h.store.Pending(c.id, after, deliverBatch)
		if err != nil {
			log.Printf("pending: %v", err)
			c.close()
			return
		}
		senders := map[string]*User{} // per batch, so profile changes show up
		for _, q := range batch {
			sender, known := senders[q.From]
			if !known {
				if sender, err = h.store.User(q.From); err != nil {
					log.Printf("sender lookup: %v", err)
					c.close()
					return
				}
				senders[q.From] = sender
			}
			raw, err := marshalFrame(map[string]any{"t": "msg", "seq": q.Seq, "from": q.From, "blob": q.Blob, "sender": sender})
			if err != nil {
				log.Printf("marshal: %v", err)
				continue
			}
			// Blocking here is the backpressure: an in-flight batch waits for buffer room.
			select {
			case c.out <- raw:
				after = q.Seq
			case <-c.done:
				return
			}
		}
		if len(batch) == deliverBatch {
			continue
		}
		select {
		case <-c.wake:
		case <-c.done:
			return
		}
	}
}

// requestCode sends a sign-up code. It is open by necessity: the caller has no
// account yet. Every limit therefore lives below it, in OTPService, plus the
// per-address limit here.
func (h *Hub) requestCode(w http.ResponseWriter, r *http.Request) {
	if h.otp == nil {
		http.Error(w, "not enabled", http.StatusNotFound)
		return
	}
	ip := h.clientIP(r)
	if !h.ips.noteNewID(ip, time.Now()) {
		writeJSON(w, http.StatusTooManyRequests, map[string]any{"ok": false, "error": "too_many_signups"})
		return
	}
	var body struct {
		Phone string `json:"phone"`
	}
	if json.NewDecoder(io.LimitReader(r.Body, 4096)).Decode(&body) != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"ok": false, "error": "bad_request"})
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 30*time.Second)
	defer cancel()
	err := h.otp.Request(ctx, body.Phone)
	switch {
	case err == nil:
		writeJSON(w, http.StatusOK, map[string]any{
			"ok": true, "retry_after": int(codeResendWait.Seconds()), "via": h.otp.Via(),
		})
	case errors.Is(err, errBadPhone), errors.Is(err, errTooSoon), errors.Is(err, errPhoneQuota),
		errors.Is(err, errPhoneInUse), errors.Is(err, errSMSBudget), errors.Is(err, errNoTelegram):
		writeJSON(w, http.StatusOK, map[string]any{"ok": false, "error": err.Error()})
	default:
		log.Printf("send code: %v", err)
		writeJSON(w, http.StatusOK, map[string]any{"ok": false, "error": "sms_failed"})
	}
}

// startBotVerify opens a bot conversation for a would-be account and tells the app
// which link to open. Nothing is proven yet; the bot does that.
func (h *Hub) startBotVerify(w http.ResponseWriter, r *http.Request) {
	if h.bot == nil {
		http.Error(w, "not enabled", http.StatusNotFound)
		return
	}
	if !h.ips.noteNewID(h.clientIP(r), time.Now()) {
		writeJSON(w, http.StatusTooManyRequests, map[string]any{"ok": false, "error": "too_many_signups"})
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 15*time.Second)
	defer cancel()
	nonce, link, err := h.bot.Start(ctx)
	if err != nil {
		log.Printf("bot start: %v", err)
		writeJSON(w, http.StatusOK, map[string]any{"ok": false, "error": "server_error"})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "nonce": nonce, "url": link})
}

// pollBotVerify is how the app learns the bot is done. It says nothing about which
// number was proven, only that one was.
func (h *Hub) pollBotVerify(w http.ResponseWriter, r *http.Request) {
	if h.bot == nil {
		http.Error(w, "not enabled", http.StatusNotFound)
		return
	}
	var body struct {
		Nonce string `json:"nonce"`
	}
	if json.NewDecoder(io.LimitReader(r.Body, 4096)).Decode(&body) != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"ok": false, "error": "bad_request"})
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 15*time.Second)
	defer cancel()
	ticket, err := h.bot.Poll(ctx, body.Nonce)
	if err != nil {
		// Not an error the app shows: it simply means "not yet".
		writeJSON(w, http.StatusOK, map[string]any{"ok": false, "error": "waiting"})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "ticket": ticket})
}

func (h *Hub) botUpdate(w http.ResponseWriter, r *http.Request) {
	if h.bot == nil {
		http.Error(w, "not enabled", http.StatusNotFound)
		return
	}
	h.bot.HandleUpdate(w, r)
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}
