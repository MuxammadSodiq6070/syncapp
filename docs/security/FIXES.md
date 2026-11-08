# What the audit found, and what changed

`REPORT.md` describes the code as it was on 2026-11-07 before any fix. This file maps
each confirmed finding to the change that closed it and the test that holds it closed.
Run the tests with the commands in the repository README.

## Confirmed findings

| Finding | Fix | Regression test |
|---|---|---|
| `core/client.cpp:peer-json-unbounded-nesting` — a deeply nested envelope crashed the app, and the gateway redelivered it on every reconnect | Depth is counted before any value is built (`json_depth_ok`, limit 32); over-deep payloads are dropped and acked | `core_tests` "deep" case: a 1,000,000-level payload stores nothing and the process survives |
| `core/client.cpp:message_json-reply-preview-type-error` — a non-string field in peer content made whole chat and message lists fail to load | Every peer payload is rebuilt field by field with the right types (`clean_content`, `clean_story`); list reads also skip a row they cannot read | `core_tests` "poison" case: `getChats` and `getMessages` both succeed |
| `core/client.cpp:unguarded-posted-jobs-and-helper-threads` — an exception on a worker or helper thread terminated the process | Both the job loop and every helper body catch and report instead | covered indirectly: the tests above would abort the suite if it still escaped |
| `core/client.cpp:envelope-replay-no-freshness` — a relay could replay old traffic to revert edits, drop re-added members and restore deleted chats | Every envelope carries an id and a send time, each is accepted once, and the record outlives chat deletion; edits carry their own time | `core_tests` "replay" case: replayed edits, leaves, deletes and messages change nothing |
| `core/client.cpp:on_group-first-writer-claims-group-id` — whoever wrote first owned a group id | A group id is now `hash(creator, salt)` and a new group must prove it | `core_tests` "squat" case, including after the chat is deleted |
| `core/client.cpp:on_group-left-state-bypasses-request-inbox` — a stranger's group skipped the request inbox | A group that does not contain you is never created | `core_tests` "inbox" case |
| `core/client.cpp:on_edit-on_delete-no-membership-check` — a removed member could still rewrite history | Both handlers require current membership | `core_tests` "removed" case |
| `core/client.cpp:media-cache-unbounded-no-lifecycle` — decrypted media outlived its message and was unbounded | Cached files are removed with their message, story or chat; story downloads are capped per sender, in flight and in total | `core_tests` "cache" case |
| `gateway/store.go:Enqueue:row-count-only-recipient-quota` — one sender could fill a recipient's queue | Quotas count bytes as well as rows, each sender gets a share, and undelivered envelopes expire | `TestQueueQuotas` |
| `gateway/media.go:Save:no-aggregate-byte-quota` — uploads could fill the disk | Per-identity and total byte budgets, checked before the bytes are accepted; media moved to Supabase Storage | `TestMediaQuotas` |
| `gateway/hub.go:handleSend:transient-unmetered-send-buffer` — a stranger's flood disconnected someone | Traffic caused by others is best-effort and dropped; only a client's own replies can close it | `TestTransientCannotDisconnectSomeone`, `TestTransientSizeLimit` |
| `gateway/store.go:SearchUsers:prefix-walk-enumerates-directory` — the whole directory, and everyone's activity, could be walked | Exact match or a 4-character prefix, results carry no activity, and presence needs both sides to ask | `TestProfileAndSearch`, `TestPresenceIsMutual` |
| `gateway/ai.go:AIService.allow:per-key-spend-limit` — free keys meant unbounded spend | Service-wide per-minute and per-day budgets, a per-identity slot cap, and the call is cancelled when the caller leaves | `TestAIBudgets`, `TestAICancelledWhenClientLeaves` |
| `gateway/market.go:PostListing:full-scan-under-write-lock` — each post scanned the whole table and stalled every other write | Counted with an index under a per-seller lock, with a total cap and a background sweep | `TestMarketplace` |

## Leads that needed validation

| Lead | What changed |
|---|---|
| `core/net.cpp:http_request-unbounded-response-body` | Responses are bounded while they are read, with an overall deadline (`TestHttpCap` in `core_tests`) |
| `core/db.cpp:local-store-default-file-mode` | The database and its folder are created private to the user, and media files with mode 600 |
| `app/android-manifest:auto-backup-not-disabled` | Still open: no backup rules are declared. Decide whether the data folder should be backed up at all |
| `app/message_bubble.dart:open-file-os-sniffed-peer-bytes` | Still open: a peer's file still opens in the OS handler without a type or a prompt |

## Also changed, beyond the findings

- TLS: the core speaks `wss://` and verifies certificates against bundled CA roots.
- The gateway's address is fixed at build time; the in-app server switch is gone.
- Per-IP limits on connections and on new identities, since identities are free.
- Envelopes must be base64, so the relay cannot be used to store arbitrary text.
- Vendored dependencies are recorded in `core/third_party/README.md`.

## Not closed

The coverage critic listed seven areas this `quick` run never hunted; they are in
`coverage-ledger.json` as `deferred`. A second audit pass should start there, and should
also cover the deployment, which did not exist when this one ran.
