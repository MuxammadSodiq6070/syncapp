# Going live

What is already done, and what is left. Everything in the second list needs an account
or a device, so it cannot be done from the repository.

## Done

| Piece | State |
|---|---|
| Gateway | `wss://sync-gateway.fly.dev`, one Fly machine in `sin`, card added so it stays running (~$3.69/month) |
| Database | Supabase Postgres, `sync_gateway` schema, created on start |
| Media | Supabase Storage, private bucket, ciphertext only |
| Transport | TLS end to end; the core verifies the certificate chain |
| Privacy policy | `https://sync-gateway.fly.dev/privacy` |
| Release signing | real upload key; the APK is signed with it, not the debug key |
| Sign-up | @syncapp_smsbot proves the number, free of charge; webhook registered and confirmed by Telegram |
| Sign-up verification | enforced by the gateway: the code, the limits and the expiry are all server-side, one number means one account, and only a keyed hash of the number is stored |
| Paid alternatives | Telegram Gateway, Eskiz SMS and Firebase are all written and tested, and switch by environment variable. `docs/VERIFICATION.md` |
| Service chat | Sync's own verified chat, carrying the welcome and sign-in notices; saved messages is local-only |
| Audit fixes | `docs/security/FIXES.md`, each with a regression test |

Verified by running, not by reading: two clients exchanged encrypted messages, media and
groups through the live gateway; a message sent while the recipient was offline arrived
when they came back; the Go suite passes under the race detector; the Flutter suite and
analyzer are clean.

## Left to do

### Before the first real user

1. **Test sign-up on a real phone.** Install `dist/sync-arm64.apk`, tap *Continue with
   Telegram*, share your number with @syncapp_smsbot, come back. This is the one path
   that cannot be tested from here — the webhook needs a real signature from Telegram,
   which cannot be forged, by design — and the anonymous route is gone, so a failure
   here blocks everyone. If it fails, `fly logs -a sync-gateway` says why.
2. **Rotate the three secrets that were pasted into a chat transcript**: the bot token
   (`/revoke` in @BotFather, then `fly secrets set TELEGRAM_BOT_TOKEN=...`), the Eskiz
   password, and the Telegram Gateway token. Only the bot token is in use.
3. **Clear the test data** left by the end-to-end runs:
   ```sh
   cd gateway && set -a && . ./.env && set +a && psql "$DATABASE_URL" -c "truncate sync_gateway.users, sync_gateway.queue, sync_gateway.queue_usage, sync_gateway.queue_share, sync_gateway.watches, sync_gateway.media, sync_gateway.market"
   ```
4. **Rotate the leaked Firebase CLI token.** `firebase-debug.log` in the repository root
   contains a token in plain text:
   ```sh
   npx firebase-tools logout --token "$(grep -oP '(?<=--token )\S+' firebase-debug.log)" && rm firebase-debug.log
   ```
5. **Remove the unused Fly apps** from the failed first attempts:
   ```sh
   fly apps destroy sync-still-waterfall-49 sync-verdant-fern-7266 sync-windblown-wave-7332
   ```

### Before the Play Store

6. **Fill in the Data safety form**: phone number, photos, files, location, and the fact
   that AI chats and Marketplace listings are not end-to-end encrypted.
7. **Point the store's privacy policy field** at the URL above.

   The Play App Signing fingerprint no longer needs registering anywhere: sign-up goes
   through the gateway and a Telegram bot, and nothing in the app checks a signing key.

### Worth doing soon

8. **Decide on Android backup.** No backup rules are declared, so the platform default
   applies to a folder holding unencrypted metadata and decrypted media. A restore can
   also separate the database from its keystore key and leave the app unable to start.
9. **Warn before opening a peer's file.** A received file opens in the OS handler with
    no type and no prompt, under a name the sender chose.
10. **Watch the gateway.** `fly logs -a sync-gateway`. It runs as a single machine, so a
    crash is an outage; Fly restarts it, but nothing alerts you.
11. **Keep committing.** The repository is under git now, with one commit holding the
    whole project. Commit each change from here so a bad one can be undone.
12. **Keep a copy of `SYNC_PHONE_HASH_KEY` somewhere safe**, outside Fly. Losing it
    unbinds every number already registered; there is no recovering it.

## Limits to keep in mind

- **The gateway must stay running.** Messages are relayed over a long-lived
  WebSocket, so a host that sleeps or recycles the process drops every connection.
  This rules out free tiers that idle out.
- **One gateway machine.** Presence, rate limits and AI budgets are in memory. A second
  machine would double every limit and break presence. Scaling needs Redis first.
- **The phone hash key is permanent.** Changing `SYNC_PHONE_HASH_KEY` would unbind every
  number already registered. It is a Fly secret; keep a copy somewhere safe.
- **Signing up needs Telegram.** Somebody without Telegram cannot create an account
  until one of the paid paths is switched on, and every one of those costs money or
  needs a company. This is the real price of the free option, and it is the single
  biggest limit on who can use Sync.
- **The bot must stay reachable.** If the webhook is lost — a changed public URL, a
  revoked token — sign-up stops silently for new users while everyone already
  registered carries on. The start-up log is the only thing that says so.
- **No push notifications.** Messages arrive only while the app is open.
- **No calls.** The buttons show a notice.
