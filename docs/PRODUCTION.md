# Going live

What is already done, and what is left. Everything in the second list needs an account
or a device, so it cannot be done from the repository.

## Done

| Piece | State |
|---|---|
| Gateway | `wss://sync-gateway.fly.dev`, one Fly machine in `sin` |
| Database | Supabase Postgres, `sync_gateway` schema, created on start |
| Media | Supabase Storage, private bucket, ciphertext only |
| Transport | TLS end to end; the core verifies the certificate chain |
| Privacy policy | `https://sync-gateway.fly.dev/privacy` |
| Release signing | real upload key; the APK is signed with it, not the debug key |
| Sign-up | a Telegram bot proves the number, free of charge. Needs a bot token, which only you can make |
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

0. **The Fly machine stops every five minutes.** The account is on a trial with no
   card, and the log says so on each stop:
   `Trial machine stopping. To run for longer than 5m0s, add a credit card`. Every
   WebSocket is dropped when it stops, and connections are refused for a second or
   two while it restarts. Nothing else on this list matters until this is settled:
   add a card at `https://fly.io/trial` (one small machine is roughly $2–5 a month),
   or move the gateway to another host. `gateway/DEPLOY.md` covers what a host needs.
1. **Make the Telegram bot. Nothing works until this is done.** Open @BotFather in
   Telegram, send `/newbot`, give it a name and a username ending in `bot`. It replies
   with a token. Then:
   ```sh
   fly secrets set TELEGRAM_BOT_TOKEN='...' TELEGRAM_BOT_USERNAME='<the username>' \
     SYNC_PUBLIC_URL='https://sync-gateway.fly.dev' -a sync-gateway
   ```
   The gateway registers the webhook itself on the next start. Confirm with
   `fly logs -a sync-gateway`: it should say `bot webhook set on …/bot/update`. If it
   says `bot webhook NOT set`, sign-up will not work and the line says why.

   This costs nothing, now or ever. While no bot token is set the gateway falls back
   to the paid Telegram Gateway path, which has no credit on it, so sign-up fails.
2. **Test sign-up on a real phone.** Install the APK, tap *Continue with Telegram*,
   share your number in the bot, come back. This is the one path that cannot be tested
   from here, and the anonymous route is gone, so a failure here blocks everyone.
3. **Rotate the two secrets that were pasted into a chat transcript**: the Eskiz
   password (in the Eskiz dashboard) and the Telegram Gateway token (in its account
   settings). Neither is in use, so this is tidying rather than urgent.
4. **Clear the test data** left by the end-to-end runs:
   ```sh
   cd gateway && set -a && . ./.env && set +a && psql "$DATABASE_URL" -c "truncate sync_gateway.users, sync_gateway.queue, sync_gateway.queue_usage, sync_gateway.queue_share, sync_gateway.watches, sync_gateway.media, sync_gateway.market"
   ```
5. **Rotate the leaked Firebase CLI token.** `firebase-debug.log` in the repository root
   contains a token in plain text:
   ```sh
   npx firebase-tools logout --token "$(grep -oP '(?<=--token )\S+' firebase-debug.log)" && rm firebase-debug.log
   ```
6. **Remove the unused Fly apps** from the failed first attempts:
   ```sh
   fly apps destroy sync-still-waterfall-49 sync-verdant-fern-7266 sync-windblown-wave-7332
   ```

### Before the Play Store

7. **Fill in the Data safety form**: phone number, photos, files, location, and the fact
   that AI chats and Marketplace listings are not end-to-end encrypted.
8. **Point the store's privacy policy field** at the URL above.

   The Play App Signing fingerprint no longer needs registering anywhere: sign-up goes
   through the gateway and a Telegram bot, and nothing in the app checks a signing key.

### Worth doing soon

9. **Decide on Android backup.** No backup rules are declared, so the platform default
   applies to a folder holding unencrypted metadata and decrypted media. A restore can
   also separate the database from its keystore key and leave the app unable to start.
10. **Warn before opening a peer's file.** A received file opens in the OS handler with
    no type and no prompt, under a name the sender chose.
11. **Finish the translations.** Every string that goes through `tr()` exists in all 13
    languages, but roughly 91 user-visible strings are still hardcoded in English in
    the screens, mostly in settings, chat details, the menu and the AI screens. In
    Uzbek the app reads as half translated. Nothing is broken; it just is not finished.
12. **Watch the gateway.** `fly logs -a sync-gateway`. It runs as a single machine, so a
    crash is an outage; Fly restarts it, but nothing alerts you.
13. **Put the repository under version control.** There is no `.git` here, so nothing
    records what changed or lets a bad change be undone. `git init` and a first commit
    cost a minute and are worth more than any item above.
14. **Keep a copy of `SYNC_PHONE_HASH_KEY` somewhere safe**, outside Fly. Losing it
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
