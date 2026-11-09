# Sign-up verification

One phone number holds one account at a time. Verifying a number that already has an
account takes it over: the previous identity is erased and the new one starts empty.
That is deliberate — somebody moving to another phone, or reinstalling without their
recovery key, arrives with a fresh identity, and refusing them would shut them out of
their own number permanently. Telegram and Signal work the same way, and accept the
same trade-off: whoever controls the number can claim the account.

Four ways of proving a number are written,
tested and compiled into the gateway. **Nothing has been deleted.** Exactly one is in
force at a time, chosen by environment variables, and the gateway logs which on every
start, so a misconfigured deployment is loud rather than silently open.

The order of precedence is fixed in `main.go`: bot, then a code provider, then
Firebase, then open. Switching is a matter of secrets and a restart — no code change,
no rebuild of the app.

| In force when | Path | Cost | What it needs |
|---|---|---|---|
| `TELEGRAM_BOT_TOKEN` is set | **Telegram bot** (current) | nothing | a bot from @BotFather |
| else `TELEGRAM_GATEWAY_TOKEN` | Telegram Gateway | $0.01 a code | credit on Fragment |
| else `ESKIZ_EMAIL`+`ESKIZ_PASSWORD` | Eskiz SMS | 30–40 so'm a code | a company with an INN |
| else `FIREBASE_PROJECT_ID` | Firebase Phone Auth | per-SMS, Blaze | a card, a $50 hold |
| none of the above | open — anyone can register | nothing | nothing |

All four store only a keyed hash of the number (`SYNC_PHONE_HASH_KEY`), never the
number itself. That key must never change: every existing number would stop matching,
and anyone could register again with a number that already has an account.

## 1. Telegram bot — in use

The app asks the gateway for a one-time nonce and opens `t.me/<bot>?start=<nonce>`.
The person taps Start, then the one button the bot offers, which is a Telegram
`request_contact` button. Telegram itself sends the number, the gateway checks that
the shared contact is the sender's own (`contact.user_id == from.id` — a contact card
can be forwarded, so without this check anyone could sign up as anyone), and issues a
single-use ticket. The app polls, gets the ticket, and presents it when it registers.

Free, forever: a bot costs nothing and Telegram does the verifying. No contract, no
INN, no card, no per-message price.

```sh
fly secrets set TELEGRAM_BOT_TOKEN='...' TELEGRAM_BOT_USERNAME='SyncVerifyBot' \
  SYNC_PUBLIC_URL='https://sync-gateway.fly.dev' -a sync-gateway
```

`SYNC_PUBLIC_URL` is required: the gateway registers the webhook at
`<public-url>/bot/update` on start-up. A webhook, not long polling, because an
incoming request also wakes a machine Fly has put to sleep.

The webhook path is public, so Telegram's `secret_token` is what separates a real
update from anyone who guesses the path. The gateway generates that secret at start-up
and compares it in constant time; a forged update is refused with 403 and proves
nothing. This is covered by `TestBotWebhookNeedsTheSecret`.

Limits: a nonce is good for 15 minutes, a ticket for 10, and a ticket can be spent
once. Per-IP sign-up limits apply to `/verify/start` as they do everywhere else.

**The one real drawback:** the person needs Telegram. There is no way around that on
this path, which is why the others are kept.

## 2. Telegram Gateway — written, needs credit

Telegram's paid verification platform. The code arrives in Telegram's own
"Verification Codes" chat; no bot, and the person does nothing but read it. $0.01 a
delivered code, no entry fee, no company registration.

Funding goes through Fragment and only in TON: `gateway.telegram.org` →
*Add Funds on Fragment*. Unspent balance cannot be withdrawn or refunded. Messages to
the number the Gateway account itself logged in with are free, which is enough to test
the whole flow without paying anything.

Each delivery is two calls: `checkSendAbility` first, then `sendVerificationMessage`
carrying its `request_id`. That ordering matters for money — a number with no Telegram
costs nothing, and passing the `request_id` makes the second call free, so one
delivered code is charged once. See `telegram.go`.

```sh
fly secrets unset TELEGRAM_BOT_TOKEN -a sync-gateway   # the bot wins while it is set
fly secrets set TELEGRAM_GATEWAY_TOKEN='...' -a sync-gateway
```

## 3. Eskiz SMS — written, blocked by Uzbek regulation

Real SMS, 30–40 so'm each, which is the cheapest per message of any paid option here.
Blocked for a private person: Uzbek operators require a legal entity or a YaTT with an
INN, and Eskiz will not approve a message template without one. Registering a YaTT
costs about 370,800 so'm online plus ongoing tax obligations, and Eskiz asks a further
300,000 so'm for the contract.

Eskiz delivers only text matching a template its moderators approved, so the wording
lives with the sender (`eskiz.go`) and must match the approved text exactly:

```
Sync: tasdiqlash kodi %s. Hech kimga bermang.
```

```sh
fly secrets unset TELEGRAM_BOT_TOKEN TELEGRAM_GATEWAY_TOKEN -a sync-gateway
fly secrets set ESKIZ_EMAIL='...' ESKIZ_PASSWORD='...' -a sync-gateway
# optional: SYNC_SMS_TEMPLATE if the approved wording differs, ESKIZ_FROM for a
# sender name of your own, SYNC_SMS_MAX_PER_DAY to cap the daily spend.
```

## 4. Firebase Phone Auth — written, superseded

The app verifies the number with Firebase and hands the gateway the resulting ID
token; the gateway checks the signature against Google's own keys, so a changed app
cannot skip the step. Needs the Blaze plan, a card, and a temporary $50 authorisation
on it, and costs more per message than either Telegram path. Both Android signing
fingerprints are already registered on the project.

```sh
fly secrets unset TELEGRAM_BOT_TOKEN TELEGRAM_GATEWAY_TOKEN ESKIZ_EMAIL ESKIZ_PASSWORD -a sync-gateway
fly secrets set FIREBASE_PROJECT_ID='syncapp-384b8' -a sync-gateway
```

## What the app does

The app does not choose. It tries the bot first; a gateway with no bot configured
answers `/verify/start` with 404, and the app falls back to the phone-and-code screens,
which serve paths 2 and 3 alike — the gateway tells it which one actually carried the
code so the screen can say "sent to Telegram" or "sent by SMS" rather than guessing.
Path 4 uses the Firebase SDK in the app and the `setAuthToken` request.

Every limit lives on the gateway: the resend wait, the per-number daily cap, the
attempt count, the expiry and the service-wide daily budget. A changed app gains
nothing by asking more often.

## Rejected without being written

- **International SMS** (Twilio, Plivo): $0.31–0.46 a message to Uzbekistan, 100 times
  Eskiz, plus sender-ID registration for UCELL. Not viable.
- **Email**: most people here would not follow it, and it proves less than a number.
- **Open sign-up**: free, and the default when nothing is configured, but it leaves
  nothing between the service and bulk account creation.
- **Play Integrity**: free to 10,000 a day and invisible to the person, but it attests
  a device rather than a person, so one phone can still make many accounts. Worth
  adding *alongside* a path above, not instead of one.
