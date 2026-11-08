# Running the gateway

The gateway holds every live WebSocket and keeps presence, rate limits and AI budgets
in memory, so it runs as **one long-lived process**. All durable state is in Supabase,
so that process needs no disk of its own.

## Why not Vercel

Vercel runs functions with a maximum duration (300s on Hobby, 800s on Pro) and may run
several instances at once. A WebSocket would be cut at that limit, and with more than
one instance a message sent through instance A would not wake a recipient connected to
instance B. Moving there means adding Redis for presence and wake-ups, and accepting a
reconnect every few minutes. Any host that runs a normal process avoids all of that.

## Fly.io

```sh
fly launch --no-deploy --copy-config
fly secrets set DATABASE_URL='...' SUPABASE_URL='...' SUPABASE_SERVICE_ROLE_KEY='...'
fly secrets set SYNC_PHONE_HASH_KEY='...'   # 32+ chars, and never changed afterwards
# Sign-up: a Telegram bot, which costs nothing. docs/VERIFICATION.md has the rest.
fly secrets set TELEGRAM_BOT_TOKEN='...' TELEGRAM_BOT_USERNAME='SyncVerifyBot'
fly secrets set SYNC_PUBLIC_URL='https://sync-gateway.fly.dev'
fly secrets set ANTHROPIC_API_KEY='...'     # optional: enables the AI screens
fly deploy
```

`fly secrets` keeps these out of the image and out of the repository. Use the Supabase
**session pooler** connection string (`...pooler.supabase.com`): direct connections are
IPv6-only, which most hosts cannot reach.

Point the app at `wss://<app-name>.fly.dev` — Fly terminates TLS, and the core verifies
the certificate against its bundled roots.

## Anywhere else

Railway, Render, or a plain VPS work the same way: one process, the same environment
variables, TLS in front. On a VPS, put Caddy or nginx in front for the certificate, or
pass `-tls-cert` and `-tls-key` to the gateway itself.

Keep it to one instance until presence and the rate limiters move to Redis.
