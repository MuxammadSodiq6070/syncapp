// Sync gateway: authenticated WebSocket relay, offline queue and blob storage.
// It only ever sees ciphertext: message and media bodies are end-to-end encrypted.
package main

import (
	"context"
	"flag"
	"log"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"
)

func loadEnv(path string) {
	data, err := os.ReadFile(path)
	if err != nil {
		return
	}
	for _, line := range strings.Split(string(data), "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		parts := strings.SplitN(line, "=", 2)
		if len(parts) == 2 {
			k := strings.TrimSpace(parts[0])
			v := strings.TrimSpace(parts[1])
			if len(v) >= 2 && ((v[0] == '"' && v[len(v)-1] == '"') || (v[0] == '\'' && v[len(v)-1] == '\'')) {
				v = v[1 : len(v)-1]
			}
			if os.Getenv(k) == "" {
				_ = os.Setenv(k, v)
			}
		}
	}
}

func envOr(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

func main() {
	loadEnv(".env")
	loadEnv(filepath.Join("gateway", ".env"))
	addr := flag.String("addr", ":"+envOr("PORT", "8787"), "listen address")
	dataDir := flag.String("data", "./data", "folder for upload spooling, and for media when Supabase Storage is not configured")
	mediaTTL := flag.Duration("media-ttl", 30*24*time.Hour, "how long media blobs are kept")
	perOwner := flag.Int64("media-per-user", 1<<30, "stored media bytes allowed per identity")
	total := flag.Int64("media-total", 20<<30, "stored media bytes allowed in total")
	tlsCert := flag.String("tls-cert", "", "TLS certificate file; leave empty behind a TLS-terminating proxy")
	tlsKey := flag.String("tls-key", "", "TLS key file")
	ipHeader := flag.String("client-ip-header", "", "header a trusted proxy sets to the client address, such as X-Forwarded-For; only set this behind such a proxy")
	flag.Parse()

	databaseURL := os.Getenv("DATABASE_URL")
	if databaseURL == "" {
		log.Fatal("DATABASE_URL is required. See gateway/.env.example")
	}

	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()

	store, err := OpenStore(ctx, databaseURL)
	if err != nil {
		log.Fatalf("open store: %v", err)
	}
	defer store.Close()

	var blobs BlobStore
	serviceKey := envOr("SUPABASE_SERVICE_ROLE_KEY", os.Getenv("SUPABASE_SECRET_KEY"))
	if url := os.Getenv("SUPABASE_URL"); url != "" && serviceKey != "" {
		blobs, err = NewSupabaseBlobs(ctx, url, serviceKey, envOr("SYNC_MEDIA_BUCKET", "sync-media"))
		log.Printf("media: Supabase Storage")
	} else {
		blobs, err = NewDiskBlobs(filepath.Join(*dataDir, "media"))
		log.Printf("media: local disk (set SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY for Supabase Storage)")
	}
	if err != nil {
		log.Fatalf("open media: %v", err)
	}
	media, err := NewMediaStore(store, blobs, MediaLimits{PerOwner: *perOwner, Total: *total, TTL: *mediaTTL}, filepath.Join(*dataDir, "spool"))
	if err != nil {
		log.Fatalf("open media store: %v", err)
	}

	var hasher *PhoneHasher
	if key := os.Getenv("SYNC_PHONE_HASH_KEY"); key != "" {
		if hasher, err = NewPhoneHasher(key); err != nil {
			log.Fatalf("verification: %v", err)
		}
	}
	verifier, err := NewVerifier(os.Getenv("FIREBASE_PROJECT_ID"), hasher)
	if err != nil {
		log.Fatalf("verification: %v", err)
	}

	// A Telegram bot is the path in use: it costs nothing at all, because Telegram
	// itself vouches for the number when the person taps the share button. The paid
	// paths stay compiled and switchable, and are chosen only when no bot is
	// configured, so moving to one of them is a matter of secrets and a restart.
	bot, err := NewBotVerifier(os.Getenv("TELEGRAM_BOT_TOKEN"), os.Getenv("TELEGRAM_BOT_USERNAME"),
		store, hasherFunc(hasher))
	if err != nil {
		log.Fatalf("bot sign-up: %v", err)
	}

	// Whoever delivers a code, the gateway makes it and checks it, so the limits and
	// the spending stay ours. Telegram's paid platform wins over Eskiz when both are
	// set: it needs no company registration.
	var sender CodeSender
	senderName := ""
	switch tgToken, eskizEmail, eskizPass := os.Getenv("TELEGRAM_GATEWAY_TOKEN"),
		os.Getenv("ESKIZ_EMAIL"), os.Getenv("ESKIZ_PASSWORD"); {
	case tgToken != "":
		sender, senderName = NewTelegramSender(tgToken), "a code sent through Telegram"
	case eskizEmail != "" && eskizPass != "":
		sender = NewEskizSender(eskizEmail, eskizPass, os.Getenv("ESKIZ_FROM"),
			os.Getenv("SYNC_SMS_TEMPLATE"))
		senderName = "a code sent by Eskiz SMS"
	}

	hub := NewHub(store, media)
	hub.bot = bot
	// Exactly one of these ends up in force, and the log says which, so a
	// misconfigured deployment is obvious rather than silently open.
	switch {
	case bot != nil:
		log.Printf("sign-up: sharing a number with the Telegram bot @%s is required", bot.username)
		if public := os.Getenv("SYNC_PUBLIC_URL"); public != "" {
			// Not fatal: the gateway still serves everyone already signed up, and the
			// log says plainly why a new sign-up would not work.
			wctx, cancel := context.WithTimeout(ctx, 30*time.Second)
			if err := bot.SetWebhook(wctx, public); err != nil {
				log.Printf("bot webhook NOT set, so sign-up will not work: %v", err)
			} else {
				log.Printf("bot webhook set on %s/bot/update", public)
			}
			cancel()
		} else {
			log.Printf("SYNC_PUBLIC_URL is empty, so no bot webhook was set and sign-up will not work")
		}
	case sender != nil:
		if hasher == nil {
			log.Fatal("a code provider needs SYNC_PHONE_HASH_KEY: that key is what keeps numbers out of the database")
		}
		budget, _ := strconv.Atoi(os.Getenv("SYNC_SMS_MAX_PER_DAY"))
		hub.otp = NewOTPService(store, sender, hasher.Hash, budget)
		log.Printf("sign-up: %s is required", senderName)
	case verifier != nil:
		hub.verifier = verifier
		log.Printf("sign-up: a phone number verified through Firebase is required")
	default:
		log.Printf("sign-up: OPEN. Set TELEGRAM_BOT_TOKEN to require a verified phone number.")
	}
	hub.IPHeader = *ipHeader
	srv := &http.Server{
		Addr:              *addr,
		Handler:           hub.Routes(),
		ReadHeaderTimeout: 10 * time.Second,
		IdleTimeout:       2 * time.Minute,
		MaxHeaderBytes:    16 * 1024,
	}

	go media.CleanupLoop(ctx)
	go hub.SweepLoop(ctx)
	go func() {
		<-ctx.Done()
		shutdown, done := context.WithTimeout(context.Background(), 5*time.Second)
		defer done()
		_ = srv.Shutdown(shutdown)
		hub.CloseAll()
	}()

	log.Printf("sync gateway listening on %s", *addr)
	if *tlsCert != "" {
		err = srv.ListenAndServeTLS(*tlsCert, *tlsKey)
	} else {
		err = srv.ListenAndServe()
	}
	if err != nil && err != http.ErrServerClosed {
		log.Fatalf("serve: %v", err)
	}
}
