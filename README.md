# Sync

End-to-end encrypted messenger with a Dark Liquid Glass UI, built on the TDLib model:
one native engine, a thin UI on top, and a relay that only sees ciphertext.

| Folder | What it is |
|---|---|
| `core/` | C++20 `sync_core`: TLS network thread, E2EE, SQLite store, JSON API over C FFI |
| `app/` | Flutter client (Android, iOS, macOS, Linux), talks to the core over `dart:ffi` |
| `gateway/` | Go server: authenticated relay, durable queue, media, Marketplace, optional AI |
| `docs/` | Privacy policy, store assets, and the security audit under `docs/security/` |
| `design/` | Figma frames the UI was built from |

## Live deployment

| Piece | Where |
|---|---|
| Gateway | `wss://sync-gateway.fly.dev` (Fly.io, one machine in `sin`) |
| Database and media | Supabase Postgres (`sync_gateway` schema) and Storage |
| Privacy policy | `https://sync-gateway.fly.dev/privacy` |

The app's gateway address is fixed at build time and cannot be changed from inside the
app, so a wrong or hostile address cannot be set by a user or by someone holding the
phone. Point a development build elsewhere with
`--dart-define=SYNC_GATEWAY=ws://192.168.1.10:8787`.

## Run it locally

A local Postgres is enough; Supabase is only needed to mirror production.

```bash
cd gateway && docker compose up -d && DATABASE_URL='postgresql://postgres:sync-local-only@127.0.0.1:15432/sync?sslmode=disable' go run .
```

```bash
cd app && flutter run --dart-define=SYNC_GATEWAY=ws://10.0.2.2:8787
```

`gateway/.env.example` lists every variable, including the Supabase and AI keys. Without
`ANTHROPIC_API_KEY` the AI screens say AI isn't set up; everything else still works.
Deployment is described in `gateway/DEPLOY.md`.

## Test it

```bash
cd gateway && SYNC_TEST_DATABASE_URL='postgresql://postgres:test@127.0.0.1:15433/postgres?sslmode=disable' go test -race ./...
```

```bash
cd app && flutter test
```

The C++ suite covers the crypto, the peer-message handlers and the HTTP limits on their
own, and runs a full two-client exchange when a gateway is given:

```bash
cmake -S core -B /tmp/sync_core -G Ninja -DSYNC_BUILD_TESTS=ON && cmake --build /tmp/sync_core
```

```bash
SYNC_TEST_GATEWAY=wss://sync-gateway.fly.dev /tmp/sync_core/core_tests
```

```bash
cd app && SYNC_CORE_LIB=/tmp/sync_core/libsync_core.so SYNC_TEST_GATEWAY=wss://sync-gateway.fly.dev flutter test test/native_test.dart
```

## Security model

- **Identity** is an Ed25519 key generated on the device; the user id is the public key.
  The gateway authenticates a device by a signed per-connection challenge, and never
  issues or holds an account password.
- **Sign-up** requires a verified phone number, proved through a Telegram bot. The app
  opens the bot with a one-time nonce; the person taps Start and the one button it
  offers, and Telegram itself sends the number. The gateway checks that the shared
  contact is the sender's own, then issues a single-use ticket the app presents when it
  registers, so a changed app cannot skip the step or verify itself. This costs nothing
  at all. Three paid paths — Telegram Gateway, Eskiz SMS and Firebase — are written,
  tested and switchable by environment variable; `docs/VERIFICATION.md` covers all four
  and the trade-offs. Every limit lives on the gateway — the resend wait, five codes a
  day per number, five wrong guesses, a daily cap across all numbers, a five-minute
  expiry — so a changed app gains nothing by asking more often. A number holds one
  account at a time: verifying it again from another phone takes the account over and
  erases the previous identity, because the alternative locks someone out of their own
  number for good. The number itself is never stored, only a keyed hash of it, which is
  enough to find the account it belongs to and not enough to recover the number from a
  stolen database. Reconnecting with an identity that still holds its number, including
  after restoring from a recovery key, needs no further verification.
- **Messages** are sealed per recipient: a fresh ephemeral X25519 key plus the static
  X25519 keys, through BLAKE2b into XChaCha20-Poly1305. Groups fan out one envelope per
  member. A client only accepts an encryption key that the identity itself signed, so a
  gateway cannot substitute one. Every envelope carries an id and a timestamp, and each
  is accepted once, so a relay cannot replay old traffic.
- **Transport** is TLS. The core speaks `wss://` and verifies the certificate chain and
  hostname against CA roots compiled into the app (`core/src/ca_bundle.cpp`).
- **At rest**, the identity seed, message bodies and story bodies are encrypted with a
  key from the platform keystore, and the database files are created private to the user.
  Message metadata (chat ids, timestamps, who sent what) is not encrypted.
- **Media** is encrypted with a random per-file key that travels inside the E2EE message.
  The gateway stores only ciphertext and serves it under an unguessable id.
- **Optional app lock**: a passphrase kept in the platform keystore locks the UI when the
  app is reopened. It gates the interface, not the database.
- **Sync's own two chats** are addressed by reserved name, not by key: `service` and
  `saved`. No identity can register either name, and an incoming peer message is filed
  under `u:<sender>` or a `g:` group, so neither chat can be written to by anyone else.
  **Saved messages** never leave the device: the chat has no recipients, so nothing is
  queued for the gateway. **Sync**, the service chat, is where sign-in notices arrive;
  it is the one chat the app marks verified, and the mark comes from the core's own
  chat type rather than from any field on the wire. These messages are not end-to-end
  encrypted, since the gateway writes them, and the app says so. The wire carries only
  the *name* of a notice, never its words: the app writes the sentence in the reader's
  language, so a hostile gateway cannot put a sentence of its choosing into a chat
  that shows a verified mark.

### Known limits

- **No ratchet.** Compromise of a device's long-term key exposes past messages sent *to*
  it. Sender-side forward secrecy only. Double Ratchet is the upgrade path.
- **One device per account.** A second device restored from the recovery key replaces the
  first connection and does not receive old messages. Each install reports a random
  device id, and a change means someone signed in elsewhere: the gateway says so in the
  service chat, and whichever device connects next is told, so the rightful owner hears
  about a stranger's sign-in the next time they open the app.
- **Saved messages stay on one device.** They are never sent anywhere, so a restore from
  the recovery key starts with an empty Saved Messages.
- **One account per number at a time, not forever.** Verifying a number that already
  has an account takes that account over: the previous identity is erased and the new
  one starts empty. Without this, moving to another phone or reinstalling without the
  recovery key would shut someone out of their own number permanently. The trade-off is
  the one Telegram and Signal accept: whoever controls the number can claim the account.
  The app lock and the recovery key are what guard what is on the device itself.
- **The hash key must never change.** Every existing number would stop matching, so a
  number that already has an account would look free.
- **Key directory trust.** The gateway maps usernames to ids. Safety numbers (chat
  details > Verify encryption) detect a lying gateway, but only if people compare them.
- **Cached media** is decrypted on disk in the app's private folder, and is removed when
  its message or story goes.
- **Presence** is mutual: two people see each other only when both have added the other.
- **Not E2EE by design:** Marketplace listings (public) and AI chats (the gateway and the
  model provider see them). Both are labelled in the UI.
- **Translations**: 13 languages, complete. All 173 keys the screens use exist in every
  one of them, checked mechanically rather than by eye. Only three strings are left in
  the source on purpose, because they are names: `Sync`, `Sync AI` and the `Travel
  Buddy` persona. Strings that take a name or a count use `trp()` with a `%s`
  placeholder, so each language puts the value where its own grammar wants it.

## Not built

- Voice and video calls: the buttons from the design show a notice. Needs WebRTC and TURN.
- Push notifications: messages arrive only while the app is connected. Needs FCM/APNs.
- Scaling past one gateway machine: presence, rate limits and AI budgets live in memory,
  so a second machine needs Redis first.

## iOS and macOS

These builds need a Mac and have not been compiled. `sync_core.podspec` at the repo root
packages the core; add it to the generated Podfile inside the target block:

```ruby
pod 'sync_core', :path => '../..'
```
