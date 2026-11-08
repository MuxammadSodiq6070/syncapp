# Sync security audit, run 1

**Profile:** quick, which is a partial pass and not a complete audit. **Scope:** core/src, core/include, gateway, app/lib, app/android, app/ios. **Source ref:** no git; tree sha256 58d57a82060b3780. **Execution:** sandboxed source and local checks only; no deployed service was contacted. **Prior runs:** none. **Method:** cloudflare/security-audit-skill at c1c8a8c.

**Deviations from the skill:**
- Reconnaissance done by the parent, which also wrote the code, instead of four research agents
- Candidates were verified by four fresh domain verifiers instead of one per candidate, to fit the user's usage limit; none of them hunted what it verified
- Five native and gateway candidates were promoted by verifiers from harness reproductions of the sink operation; confidence fields state where the path is source-derived

**Deferred:** seven areas the coverage critic found were not hunted; see Coverage.

## Posture

14 confirmed findings (none high or critical), 4 leads needing validation. The E2EE envelope and identity binding held under test. The main problems were availability from malformed peer data, replay by an untrusted relay, and missing resource limits on free identities. The findings describe the code as it was at the source ref above; see `FIXES.md` for what changed afterwards.

## Confirmed findings

| Severity | Title | Observed result |
|---|---|---|
| medium | Replayed envelopes revert edits, remove re-added members and restore deleted chats | Text returned to 'v2 superseded' after 'v3 current'. |
| medium | Non-string text in stored peer media content makes whole message/chat-list reads throw | Local harness: body.value("text","") on {media_id,key,text:123} throws [json.exception.type_error.302] type must be string, but is number (identical for an array). |
| medium | Peer-supplied JSON nesting depth is unbounded before a recursive copy on the worker thread, crashing the client in a redelivery loop | Local harness: J::parse of a 2,000,000-byte 1e6-deep nest succeeds, then the copy `J c = j;` crashes with Segmentation fault (core dumped), exit 139. |
| medium | Exceptions in posted completion jobs and helper threads are uncontained and abort the process | Local harness: an exception escaping a std::thread body prints 'terminate called after throwing ... |
| medium | AI rate limit follows a free self-generated key, so operator spend has no per-actor or aggregate budget | Independently reproduced. |
| medium | Each marketplace post decodes every listing under the database write lock, and the listing cap is per free key | Independently reproduced, and the shared stall the hunter inferred was measured. |
| medium | Media uploads have no per-identity or aggregate byte quota, and blobs persist for 30 days in the shared data directory | Independently reproduced. |
| medium | Recipient queue quota counts rows rather than bytes, has no expiry, and can be consumed entirely by one stranger | Independently reproduced, and the hunter's prefill was replaced by a real fill. |
| medium | Prefix search lets an identity with no known ids enumerate users and then track their presence | Independently reproduced with a separately generated population. |
| low | Peer-triggered media cache has no size limit and survives expiry and deletion | A stranger's story stored 0 rows. |
| low | Removed group members can still edit and delete their earlier messages | Controls were rejected: reaction rows=0, new message rows=0, and the non-author edit left the text unchanged. |
| low | First on_group for an unknown id makes the sender admin and blocks the real invite | admin_is_squatter=1; the chat was listed in requests; outbox recipients were squatter and outsider, not the real admin; the real admin's message stored 0 rows. |
| low | Stranger's group that omits the victim bypasses the message request inbox | Group case: main=g:bbbb(left,unread=1), requests=<empty>, title 'Stranger injected', message stored. |
| low | Transient frames from any stranger can overflow a slower client's send buffer and disconnect that client | Independently reproduced. |

### Replayed envelopes revert edits, remove re-added members and restore deleted chats

`core/client.cpp:envelope-replay-no-freshness`, medium. Likelihood medium: The operator is an explicit threat principal and only needs frames it already relays, but must choose to act maliciously. Impact medium: Integrity of displayed E2EE message text and of the victim's group membership view is altered, and deleted content can reappear. Plaintext is not disclosed.

Envelopes carry no sequence, counter or replay cache, and only msg, story and on_group have partial idempotency. A gateway operator, whom the architecture treats as untrusted, can retain a sealed frame and redeliver it. An honest gateway deletes a frame on ack, so this needs a malicious relay or an on-path injector. In the local check, this reverted a message to a superseded edit, removed a re-added member from the victim's member list so that member's next message was dropped, recreated a deleted group as a request, and restored a message into a deleted direct chat.

**Source:** `core/src/client.cpp:265`, `core/src/client.cpp:619`, `core/src/crypto.cpp:197`, `core/src/client.cpp:684`

**Principal:** Untrusted relay holding previously relayed ciphertext frames, using dummy identities only.

**Result:** Text returned to 'v2 superseded' after 'v3 current'. The member count went 0 after the leave, 1 after the ver 2 re-add, and 0 after the replayed leave, and the member's next group message stored 0 rows. The deleted group's rows went 0 then 1 with state 'request'. The deleted direct message's rows went 0 then 1 with text 'once'. Controls: replaying a msg with no intervening delete left one row, and replaying a group frame with the chat present changed nothing. Recorded in agents/verifier-peer/artifacts/evidence/verifier-peer-handlers.txt.

**Fix:** Add a per-sender monotonic counter inside the sealed payload, or persist a replay cache of envelope ids, and reject values already seen, with state that survives deleteChat. Give edits a per-message revision and leaves the group version they apply to, and keep tombstones for deleted chats and mids. Regression: repeat each replay sequence and assert state does not change.

### Non-string text in stored peer media content makes whole message/chat-list reads throw

`core/client.cpp:message_json-reply-preview-type-error`, medium. Likelihood high: One crafted first-contact message, no victim interaction; passes valid_content. Impact medium: Client-side availability: the affected chat list / message list fails to load for any filter whose latest message is the poison, and the app can be left stuck on the splash screen (source-derived); persists until local data is cleared.

valid_content requires only that media_id and key are strings for image/file messages (client.cpp:64-65), so a peer's content may also carry a non-string `text` field, which is stored verbatim (only local_path is stripped). message_json builds a reply preview with body.value("text","") (client.cpp:503); a local harness using the vendored json.hpp confirms that value(key,"") throws json type_error.302 when the stored value is a number or array. A peer can send one image/file message that replies to itself (reply_to == its own mid) with {media_id,key,text:<number>}: the row is inserted and set as the chat's last_message (client.cpp:663-665) before the initial message_json(mid) at :666 throws, which is caught by handle_frame's drop-and-ack guard, so the poison persists. Thereafter getChats (chat_json->message_json for last_message, :552/:971) and getMessages (:983) call message_json in an unguarded loop; the throw propagates to handle_request (:907-911) which turns it into a single failed reply, so the entire filter's list fails to load rather than degrading one message. On the app, refreshChats awaits all three filters with Future.wait (app_state.dart:43) and sets loaded only afterwards (:38), so one failing filter can leave the app on the splash screen (main.dart:108).

**Source:** `core/src/client.cpp:646`, `core/src/client.cpp:660`, `core/src/client.cpp:503`, `core/src/client.cpp:552`

**Principal:** A registered Sync user who can send the victim a first message.

**Result:** Local harness: body.value("text","") on {media_id,key,text:123} throws [json.exception.type_error.302] type must be string, but is number (identical for an array). See artifact native-robustness-repro.txt (T2). The request-level and app-level consequences are source-derived from the unguarded loops and handle_request catch.

**Fix:** Read the preview tolerantly and isolate per-row failures: use body.contains("text") && body["text"].is_string() before reading, and wrap the per-row message_json call in getChats/getMessages in try/catch so one bad row is skipped instead of failing the list. Optionally reject unknown/mistyped content fields in valid_content.

### Peer-supplied JSON nesting depth is unbounded before a recursive copy on the worker thread, crashing the client in a redelivery loop

`core/client.cpp:peer-json-unbounded-nesting`, medium. Likelihood high: One crafted message from any registered user, no victim interaction, trivial to build. Impact medium: Persistent client denial of service: the victim's app crashes on connect and the gateway redelivers the same message, blocking the queue until the row is removed server-side. Safe termination (stack-guard SIGSEGV), no memory corruption claimed.

handle_envelope parses decrypted peer bytes with no depth limit, then on_msg copies the content value (`J content = p.at("content")`) before any validation, using nlohmann's recursive basic_json copy constructor. A locally built harness using the vendored /target/core/third_party/nlohmann/json.hpp shows that parsing a 1,000,000-level nested array (2,000,000 bytes, well under the 8 MiB gateway frame limit) succeeds (the parser is iterative) but the subsequent copy `J c = j;` overflows the stack and the process dies with SIGSEGV. The crash is on the worker thread during handle_envelope; the ack is sent only after handle_envelope returns (client.cpp:273) and the gateway keeps unacked rows (hub.go deliverLoop), so the same poisoned envelope is redelivered on the next connection, repeating the crash. The achievable depth within the frame (~4M levels) exceeds any realistic thread/device stack, so the outcome does not depend on the device stack size.

**Source:** `core/src/client.cpp:265`, `core/src/client.cpp:627`, `core/src/client.cpp:645`

**Principal:** A registered Sync user who has the victim's 64-hex id and box_pk (obtainable via directory search).

**Result:** Local harness: J::parse of a 2,000,000-byte 1e6-deep nest succeeds, then the copy `J c = j;` crashes with Segmentation fault (core dumped), exit 139. See artifact native-robustness-repro.txt (T1).

**Fix:** Bound peer JSON depth before any recursive operation: parse decrypted peer bytes with a SAX/callback parser that rejects documents deeper than a small fixed limit (and reject over-limit before copying content), then drop-and-ack such envelopes as handle_frame already does for exceptions.

### Exceptions in posted completion jobs and helper threads are uncontained and abort the process

`core/client.cpp:unguarded-posted-jobs-and-helper-threads`, medium. Likelihood medium: Path (1) needs a hostile/MITM gateway (plausible given documented no TLS); path (2) needs a peer-planted message plus one user tap. Impact medium: Hard process termination (std::terminate/abort) of the client; recovery requires relaunch and, for path (2), is repeatable until the poison message is removed.

run()'s worker job loop (client.cpp:161 `for (auto &j : jobs) j();`) and spawn()'s helper body (client.cpp:134-139) run with no try/catch, so an exception leaving either calls std::terminate and aborts the whole process. A local harness confirms that an exception escaping a std::thread body produces 'terminate called ...' and Aborted/SIGABRT (exit 134). Two reachable sources throw there: (1) upload_file's helper calls j.value("id","") on the gateway's HTTP response (client.cpp:858) inside spawn(); value(key,"") throws type_error.302 on a non-string (reproduced), so a hostile or MITM gateway (README documents no TLS) returning {"id":123} to a media upload aborts the client. (2) download_to posts its completion to the worker (client.cpp:889), and the downloadMedia completion calls emit_message (client.cpp:1233) -> message_json, which can throw via the reply-preview type defect (fingerprint message_json-reply-preview-type-error); run()'s unguarded loop then aborts, so a peer-poisoned self-replying media message plus the user tapping download produces a hard crash. Contrast the comparison control handle_request (client.cpp:907) which catches std::exception.

**Source:** `core/src/client.cpp:855`, `core/src/client.cpp:858`, `core/src/client.cpp:135`

**Principal:** Path (1): an attacker controlling or MITMing the plain-ws gateway. Path (2): any registered peer who can send the victim a media message.

**Result:** Local harness: an exception escaping a std::thread body prints 'terminate called after throwing ... std::runtime_error' and aborts with SIGABRT (exit 134); value("id","") on {"id":123} throws type_error.302. See artifact native-robustness-repro.txt (T3, T2).

**Fix:** Wrap the worker job loop and the spawn() helper body in try/catch and route failures to the originating request's error path (or a logged drop), so untrusted input cannot abort the process.

### AI rate limit follows a free self-generated key, so operator spend has no per-actor or aggregate budget

`gateway/ai.go:AIService.allow:per-key-spend-limit`, medium. Likelihood high: Identities are free and the bypass needs only ordinary protocol use. Impact medium: Operator-funded spend beyond the intended limit and delayed or refused AI service for other users, limited by the concurrency limit of 16 and any provider-side limit; no user data is exposed and messaging is not affected.

When ANTHROPIC_API_KEY is configured, any client can create Ed25519 identities at no cost and each identity gets a fresh allowance of 20 AI requests per minute. Each request can carry up to 20000 characters of turns plus 4000 of persona and asks for up to 16000 output tokens. The only global control is a concurrency limit of 16, which limits parallelism but not total spend. One key can occupy all 16 slots by itself; other users' calls then wait for a slot and return ai_busy if none frees within the 2-minute timeout. Disconnecting does not cancel a paid call.

**Source:** `gateway/hub.go:386`, `gateway/store.go:97`, `gateway/ai.go:171`, `gateway/ai.go:178`, `gateway/ai.go:125`

**Principal:** A client that generates several Ed25519 keys and authenticates each one to a local test gateway with a mocked provider.

**Result:** Independently reproduced. Each identity got ok=20 and rate_limited=5. The mock recorded upstream_calls=60 against per_user_limit=20, with max_tokens=16000 in the request. upstream_cancelled_after_client_disconnect=false. With one key holding 16 calls, the second identity's call did not reach the mock and got no reply within 3 s; it reached the mock only after release (upstream_total=17). The 2-minute ai_busy expiry follows from source and was not waited out. No real provider was contacted, so real spend and real slot hold times were not measured.

**Fix:** Add a service-wide request and token budget per minute and per day checked before the upstream call, consider admission control for AI use since keys are free, derive the request context from the connection's done channel, cap the slots one identity can hold, and evict idle entries from hits. Regression cases: N identities together cannot exceed the global budget, one identity cannot hold every slot, and closing the connection cancels the upstream request.

### Each marketplace post decodes every listing under the database write lock, and the listing cap is per free key

`gateway/market.go:PostListing:full-scan-under-write-lock`, medium. Likelihood medium: Corrected from low: the proposed need for tens of thousands of identities is not supported. A measured stall needed 16000 listings, which is 800 free identities, and 4 connections at about 10 posts per second. The listings must first be created and persist up to 30 days. Impact medium: All gateway writes wait during each post, so message sends for every user slowed about 60 times in the fixture. Sends still succeeded, and no data was lost or exposed.

PostListing counts the seller's listings by JSON-decoding the entire market bucket inside a bbolt write transaction. bbolt has a single writer, so that scan blocks every other write in the gateway, including Enqueue, Ack, UpsertIdentity and SetLastSeen. The total number of listings has no bound because the cap of 20 applies per key and keys are free. A post refused for the cap still performs the whole scan under the lock and writes nothing, so a seller at its cap can repeat it without growing anything. market_list performs the same full decode per request, under a read transaction rather than the write lock. At 16000 listings, 4 connections sending refused posts raised the median message send latency from 13.4 ms to 823 ms.

**Source:** `gateway/market.go:151`, `gateway/market.go:47`, `gateway/market.go:50`

**Principal:** Dummy sellers on a local test gateway, with the bucket seeded directly at small sizes to measure growth and the shared stall.

**Result:** Independently reproduced, and the shared stall the hunter inferred was measured. same_key_21st=too_many_listings, other_key_first_ok=true. Refused post time was 33.8 ms at 2000 listings, 125.3 ms at 8000 and 222.9 ms at 16000; list time was 34.3 ms, 123.8 ms and 257.1 ms. At 16000 listings, send latency was p50=13.4 ms, max=14 ms when idle and p50=823 ms, max=938 ms under refused posts, with attacker_posts=250 in 24.9 s, far below the frame rate limit. Listings were seeded directly, so the time to create them through the protocol was not measured, and larger populations and more connections were not run.

**Fix:** Keep a per-seller counter or index in the same transaction so a post is constant time and a refusal needs no scan, add an aggregate listing cap or admission control, limit posts per identity, and move expiry to a background sweep. Regression cases: post time does not grow with the number of other sellers' listings, refused posts do not delay concurrent sends, and posts over the aggregate cap are refused.

### Media uploads have no per-identity or aggregate byte quota, and blobs persist for 30 days in the shared data directory

`gateway/media.go:Save:no-aggregate-byte-quota`, medium. Likelihood medium: The attack is simple but costs bandwidth proportional to the disk consumed, and retention makes it cumulative. Impact medium: Persistent consumption of the operator's disk for up to the TTL, and relay writes for all users fail once the shared volume is full. No data disclosure, and service recovers when space is freed; clients retain refused messages for retry.

Any identity can obtain a media token and reuse it for any number of uploads during its 10-minute life, then request another without limit. Each blob may be about 50 MiB and is kept for the default 30-day TTL with no deletion path. Media shares its data directory with gateway.db by default. On a private 32 MiB test volume, uploads filled the disk and message sends then failed with server_error until media was removed.

**Source:** `gateway/hub.go:385`, `gateway/hub.go:69`, `gateway/media.go:55`, `gateway/media.go:109`

**Principal:** An authenticated dummy identity uploading to a local test gateway.

**Result:** Independently reproduced. uploads_accepted=11, files=11, bytes_on_disk=11534336, per_blob_cap=52429824; expired, tampered and absent tokens each returned 401. On the 32 MiB volume: 31 uploads accepted, the next returned 500 with ENOSPC. Of 400 sends, 23 succeeded and 377 returned server_error with enqueue ENOSPC logged. After the media files were removed, a send succeeded. The gateway process did not crash. This used a small private volume, not a production disk.

**Fix:** Parse the user from the verified token and enforce per-identity and aggregate byte budgets before accepting bytes, keep the reservation through the upload, and refuse uploads above a free-space floor so the store keeps room to write. Regression cases: uploads beyond the identity budget return an error and leave no file, and uploads refused at the floor leave sends working.

### Recipient queue quota counts rows rather than bytes, has no expiry, and can be consumed entirely by one stranger

`gateway/store.go:Enqueue:row-count-only-recipient-quota`, medium. Likelihood medium: The attack needs only ordinary frames and filling a queue took about a minute with 4 free identities, but disk use costs attacker bandwidth and the denial needs an offline victim. Impact medium: Persistent disk consumption on the shared relay and delayed delivery to an offline victim. Mail is retried rather than lost, and the victim recovers by coming online.

The queue cap is 20000 rows per recipient, while a frame can be close to 8 MiB. Enqueue re-marshals the blob with HTML escaping, so stored rows can be larger than the frame: a blob of '<' characters stored at 6.00 times its size. Rows have no expiry, so a recipient key the attacker controls and never acks retains its rows indefinitely, and recipients are free to create. Strangers can also use a victim's whole allowance while the victim is offline, after which legitimate senders get queue_full until the victim reconnects and drains. The gateway has no per-sender share and no server-side block, and the per-connection frame budget resets on reconnect.

**Source:** `gateway/hub.go:360`, `gateway/hub.go:275`, `gateway/hub.go:480`, `gateway/store.go:208`, `gateway/store.go:222`

**Principal:** Authenticated strangers with no relationship to the offline dummy recipient, on a local test gateway.

**Result:** Independently reproduced, and the hunter's prefill was replaced by a real fill. large_rows=3, db_bytes_before=32768, db_bytes_after=60878848. A 1048576-byte escaped blob stored as a 6291549-byte row (ratio 6.00). 4 senders got accepted=20000 and rate_limited=0 in 69 s, stored_count=20000; the third party got ok=false error=queue_full. After the victim came online and acked, the third party got ok=true. Rate check: first connection ok=408 rate_limited=1592, probe 100 of 100 limited, after reconnect ok=300 rate_limited=0. Multi-gigabyte queues were not run: a large-row fill and any per-recipient byte total remain arithmetic.

**Fix:** Track queued bytes per recipient and per sender using the stored size, enforce a byte cap and a per-sender share of the recipient quota, expire undelivered rows after a retention period, and hold the rate budget per identity with a byte-based charge so reconnecting does not refill it. Regression cases: a large-blob sender hits the byte cap before the row cap, one sender at its share does not cause queue_full for another sender, and a reconnect does not restore the budget.

### Prefix search lets an identity with no known ids enumerate users and then track their presence

`gateway/store.go:SearchUsers:prefix-walk-enumerates-directory`, medium. Likelihood high: Uses ordinary frames at a low query count from any free identity. Impact medium: Population-wide metadata and activity patterns for users with usernames. Message content and contact relationships are not exposed.

README documents presence as visible to anyone who asks by user id. The boundary result here goes further: a new identity needs no ids at all. One-character prefix search with a limit of 20 can be walked recursively to recover every user who has set a username, including id, display name and last_seen. Those ids can then be watched for live online and offline changes, 5000 per connection and with no limit across connections. The app's onboarding requires a username, so this reaches normal app users; only an identity that never set one, such as a raw protocol client, is missed. The app refuses search terms under 2 characters, but the gateway does not enforce this.

**Source:** `gateway/hub.go:367`, `gateway/store.go:169`, `gateway/hub.go:425`, `gateway/hub.go:447`

**Principal:** A new identity on a local test gateway that knows no user ids, against 60 dummy users.

**Result:** Independently reproduced with a separately generated population. population=60, recovered=60, queries=259, search rows with last_seen=30, no_username_user_found=false. Presence: online=30, offline_with_last_seen=30. When a watched user disconnected, a live presence frame arrived with that id, online=false and last_seen set. Only dummy users on the local fixture were involved, and query counts at larger populations were not measured.

**Fix:** Enforce on the gateway an exact username or a long minimum prefix (the app's 2-character rule would not stop this walk), limit search per identity rather than per connection, omit last_seen from search and user results, and restrict presence to established contacts, for example with a mutual consent token. If the directory is intended to be public, update README to state that it can be enumerated in full. Regression cases: a short prefix returns nothing and a stranger's watch returns no presence.

### Peer-triggered media cache has no size limit and survives expiry and deletion

`core/client.cpp:media-cache-unbounded-no-lifecycle`, low. Likelihood medium: The attacker must be an accepted contact for growth, but no further user action is needed once the app refreshes stories, and every downloaded media message later deleted leaves a file. Impact low: Observed effects are retained plaintext in the app-private folder and bounded file growth on one device. A recipient could always have saved the content, reading it needs separate folder access, and full disk exhaustion was deliberately not exercised.

An accepted contact can reference one uploaded blob from many story envelopes. Each getStories downloads every image story into its own decrypted media/story_<id> file. The files are never removed: story expiry deletes only the row, and sender delete, the local deleteMessage request and deleteChat leave message media in place. This goes beyond the README's statement that cached media is decrypted in the private folder: story plaintext outlives the UI's 24-hour statement, 'Delete for everyone' leaves the recipient's plaintext file with no remaining reference in the app, and a contact can grow the victim's disk use by up to one media blob per small envelope. This record also covers the duplicate report core/client.cpp:media-cache-survives-delete-and-expiry, which has the same root cause.

**Source:** `core/src/client.cpp:638`, `core/src/client.cpp:817`, `core/src/client.cpp:1370`, `core/src/client.cpp:884`

**Principal:** An accepted contact with a dummy identity who references one encrypted blob from a local loopback fixture.

**Result:** A stranger's story stored 0 rows. 5 envelopes caused 5 media GETs and 5 plaintext files, the first checked at 1048576 bytes. After expiry there were 0 story rows and 5 files. The message file existed after sender delete (deleted=1) and after deleteChat, with 0 message rows. Recorded in agents/verifier-peer/artifacts/evidence/verifier-peer-handlers.txt. A separate two-client loopback run recorded retained plaintext after a delete in agents/hunter-app/artifacts/evidence/local-store-check.txt.

**Fix:** Unlink cached files under dir/media on story expiry, on_delete, deleteMessage and deleteChat, and on completion of a download whose row is gone or deleted, without ever removing a sender's original picked file. Cap automatic story downloads per sender and in total, with limited concurrency, and enforce kMaxMedia on download. Regression: the sequence must end with no retained files and with growth stopped at the cap.

### Removed group members can still edit and delete their earlier messages

`core/client.cpp:on_edit-on_delete-no-membership-check`, low. Likelihood medium: Any removed member with an existing message can do this at any time, unless blocked. Impact low: Limited to the attacker's own earlier messages, and edits are flagged in the UI, but removal does not stop the history being rewritten, which could mislead remaining members.

After an admin removes a member, that member can still rewrite or delete messages they wrote while a member, as shown to remaining members. Sibling handlers on_msg, on_react and on_vote reject the same sender, so revocation is inconsistent.

**Source:** `core/src/client.cpp:630`, `core/src/client.cpp:679`, `core/src/client.cpp:684`

**Principal:** A removed group member using a dummy identity and their still-valid peer keys.

**Result:** Controls were rejected: reaction rows=0, new message rows=0, and the non-author edit left the text unchanged. Edit applied ('rewritten', edited=1) and delete applied (deleted=1). Recorded in agents/verifier-peer/artifacts/evidence/verifier-peer-handlers.txt.

**Fix:** Require chat_of(mid, from) to be non-empty in on_edit and on_delete, in addition to the sender check. Regression: the same sequence must leave both messages unchanged.

### First on_group for an unknown id makes the sender admin and blocks the real invite

`core/client.cpp:on_group-first-writer-claims-group-id`, low. Likelihood low: Needs prior knowledge of the id, which in practice means being a member, delivery ahead of the invite or after a local delete, and victim acceptance. Impact medium: The victim's messages meant for the group go to attacker-chosen recipients, the real invite and the real admin's messages are lost without notice, and the attacker's member list is visible only in group info.

Anyone who knows a group id can send a target an on_group naming themselves admin before the real invite arrives, or after the target deletes the chat. The real admin's later invite is then silently rejected. In the local check, once the victim accepted the request and sent a message, it was queued only for the squatter and an outsider the squatter listed, not for the real admin, and the real admin's own group message was dropped.

**Source:** `core/src/client.cpp:635`, `core/src/client.cpp:755`, `core/src/client.cpp:754`, `core/src/client.cpp:370`

**Principal:** A group member using a dummy identity who sends the prospective member an on_group before the admin adds them.

**Result:** admin_is_squatter=1; the chat was listed in requests; outbox recipients were squatter and outsider, not the real admin; the real admin's message stored 0 rows. Control with the real invite first: admin_is_real=1, also after a later claim at ver 9000. Deleted-chat route: admin_is_squatter=1. Delivery to the outsider was not exercised because no gateway was present; the entries were only queued. Recorded in agents/verifier-peer/artifacts/evidence/verifier-peer-handlers.txt.

**Fix:** Bind the group id to its creator, for example id = hash(creator_id, random) with the creator id and random value carried in on_group, and verify it for unknown ids, or have the creator sign a genesis record that members verify. Either way, chain admin succession from that root so a later admin's invite to a new member still verifies. Regression: the squat and deleted-chat sequences must leave the squatter's claim rejected and the real invite accepted.

### Stranger's group that omits the victim bypasses the message request inbox

`core/client.cpp:on_group-left-state-bypasses-request-inbox`, low. Likelihood high: Only a user id is needed, and users are discoverable through directory search. Impact low: Bypasses an anti-spam and safety quarantine with attacker-chosen title and text, with no data disclosure or privilege gain. Core honours a block, but the group screens do not offer one; the victim can delete the chat, and the attacker can inject again under a new id.

Any identity that knows a user id can send an on_group whose member list omits the victim. on_group creates the chat, then sets state 'left'. getChats treats only 'request' as quarantined, so the attacker-titled chat appears in the main list, and on_msg accepts the attacker's messages because is_member checks the sender, not the victim. A normal stranger DM goes to the requests list instead.

**Source:** `core/src/client.cpp:635`, `core/src/client.cpp:766`, `core/src/client.cpp:652`, `core/src/client.cpp:968`

**Principal:** A stranger with a dummy identity who has only the victim's user id.

**Result:** Group case: main=g:bbbb(left,unread=1), requests=<empty>, title 'Stranger injected', message stored. Baseline DM: main=<empty>, requests=u:fa48(request,unread=1). After setBlocked in core, the sender's next message stored 0 rows. Recorded in agents/verifier-peer/artifacts/evidence/verifier-peer-handlers.txt.

**Fix:** In on_group, return without creating anything when the chat is unknown and the victim is not in members, and keep the existing 'left' transition for a known chat. In on_msg, reject group messages when local state is 'left' or the local user is not a member. Regression: the group sequence must leave main and requests empty and store no message.

### Transient frames from any stranger can overflow a slower client's send buffer and disconnect that client

`gateway/hub.go:handleSend:transient-unmetered-send-buffer`, low. Likelihood medium: Reachable by any identity, but it requires the sender to outpace the victim's drain rate, and an unpaced burst did not reliably do so. Impact low: A repeating short disconnect of one session. Queued messages are redelivered and the client reconnects within about a second at first; the memory worst case is unobserved.

A transient send requires no relationship with the target and skips the queue. The gateway places each frame in the target's 256-slot buffer and closes the target's connection when the buffer is full. A sender that outpaces the target's drain rate therefore disconnects it. Delivered frames can be larger than what the sender sent, because JSON escaping grew a blob of '<' characters to 6.00 times its size. The buffer is bounded in frames rather than bytes and there is no aggregate memory limit across connections; the worst-case retained memory is arithmetic and was not exercised.

**Source:** `gateway/hub.go:360`, `gateway/hub.go:471`, `gateway/hub.go:474`, `gateway/hub.go:149`

**Principal:** An authenticated stranger sending transient frames to an online dummy victim on a local test gateway.

**Result:** Independently reproduced. Paced sender: kicked=5/5, after 3.49 to 3.74 s, with 164 to 176 frames read of 440 to 470 sent. Control with no read delay: frames_read=600, not kicked. Escaped blob: 262144 bytes sent, 1573297-byte frame delivered (ratio 6.00). The hunter's retained file also shows that an unpaced 330-frame burst disconnected the victim in only 1 of 5 runs, and 0 of 1 in its main output, so only the paced result is relied on. Retained memory at the worst case was not exercised, and a real core client was not used as the victim.

**Fix:** Give transient traffic a separate best-effort path that drops frames when the target's buffer is above a threshold instead of closing the connection, cap the transient blob size to what typing and receipts need, and bound the send buffer in bytes as actually marshalled. Regression case: a slow reader under a transient flood stays connected and only loses transient frames.

## Needs validation

These have no severity and are not confirmed vulnerabilities.

| Title | Trace | Blocker | Next step |
|---|---|---|---|
| OS backup is not excluded for the local store, decrypted media or keystore-backed key | `app/android/app/src/main/AndroidManifest.xml:7` → `app/lib/main.dart:62` → `core/src/client.cpp:873` | Flutter and an Android emulator or device are unavailable, so the merged manifest and actual backup contents were not observed. The mapping of application support to filesDir is settled from plugin source and is no longer a blocker. | On an isolated Android emulator with dummy data, inspect the merged manifest for allowBackup and backup rules, run bmgr backupnow then a restore into a clean install, list which files under the app's files directory came back, and record whether the app starts or stops at the start error. Then set allowBackup=false or add exclusion rules and repeat as the regression case. On an iOS simulator or test device with a dummy profile, check the backup state of Application Support and the keychain item's accessibility. |
| Peer-chosen file bytes reach the OS default handler under a peer-chosen name | `core/src/client.cpp:641` → `core/src/client.cpp:873` → `app/lib/screens/message_bubble.dart:556` | The handler that a real desktop session starts through xdg-open, and the behaviour of macOS open for extensionless peer content, depend on the desktop environment and its configuration and were not observed. Only xdg-mime type detection was observed, in a sandbox with no desktop session. | On an isolated Linux desktop VM and a macOS VM with dummy files, run the platform opener on extensionless copies of harmless HTML, text and desktop-entry fixtures, and record which handler starts and whether anything runs without a further prompt. If the handler differs from the label, add a confirmation showing the detected type, and test that a mislabelled file triggers it. |
| Local database is created readable by other OS users on Linux desktop | `app/lib/main.dart:63` → `core/src/client.cpp:72` → `core/src/db.cpp:91` | The target Linux home directory mode decides reachability: a 0700 or 0750 home blocks unrelated users, and this was not established for the supported distributions. The audit host's own home is 0700, which would block the read there. | Build the Linux app on an isolated machine with a dummy profile, run stat on ~/.local/share/uz.sync.sync_app and its files, and read sync.db as a second dummy user under a 0755 home. The regression case is that the data directory is 0700 and the database files 0600 at creation. |
| Media HTTP responses are buffered in memory with no size limit or overall deadline | `core/src/client.cpp:876` → `core/src/net.cpp:275` → `core/src/net.cpp:283` | The real client memory growth and failure mode on a target device, and whether this amounts to a meaningful denial of service (the blast radius is a single client, not a shared service), were not observed; by the resource-exhaustion rules this needs a demonstrated meaningful impact, not availability alone. | In the sandbox, link core net.cpp (with crypto.cpp + vendored monocypher) into a harness, start a loopback stub server that returns `HTTP/1.1 200 OK` with a large body (e.g. 200 MiB, far above kMaxMedia), point http_request at 127.0.0.1, and assert that res.body.size() reaches the full oversized length (demonstrating no cap). Then add a running size cap (kMaxMedia + AEAD overhead) and a total-transfer deadline and confirm the read aborts with an error at the cap. |

## Hardening notes

Not findings.

- Admin succession uses MIN(user_id) applied independently by each client (core/src/client.cpp:794). An admin leave delivered to only some members splits admin views, and a member can grind a low id to be next in line.
- Harness note: one full run's pipelined rate check failed with a close 1006 on the attacker connection after 1000 unread frames. A dedicated control sending 2000 unread frames did not reproduce it in 6 attempts, so the cause is not established. The rate check was changed to read replies in chunks, and that version passed consistently; only that version is cited.
- Malicious admins can set ver near INT64_MAX (core/src/client.cpp:749, 754), which blocks every later update, including from a successor after the admin leaves.
- Message ids and story ids are a global primary key with INSERT OR IGNORE (core/src/client.cpp:657, 817), not scoped by sender or chat. A peer who learns a mid or story id and delivers it first could suppress the real item. Delivery order makes this a narrow race and it was not demonstrated.
- NativeBackend.call has no disposed check before _send. Add one so a late call fails with an error instead of passing a destroyed client pointer.
- RecoveryKeyScreen shows the key with no re-authentication, so anyone holding an unlocked device can read it; a device credential prompt would raise that bar.
- Root .gitignore does not list .env, *.pem or *.key, though app/android/.gitignore covers key.properties and keystores and no such files exist today. This directory is also not currently a git repository, so history could not be checked for past secrets.
- Static-static DH gives no protection against key-compromise impersonation: someone holding a recipient's box secret can forge messages to that recipient from any sender. The auth signature (core/src/client.cpp:241) is not bound to a gateway identity, so a malicious gateway could relay another gateway's challenge.
- The auth message is 'sync-auth-v1' plus the nonce, with no gateway identity (hub.go:233), and the client signs whatever nonce it is sent (core/src/client.cpp:238-241). A malicious gateway could relay a challenge from a different gateway and act as the client there. Not proposed as a finding because no multi-gateway boundary exists in this revision, and on a single gateway the plaintext-transport limit in README already covers network attackers.
- The open_filex plugin adds READ_MEDIA_* and READ_EXTERNAL_STORAGE to the Android permission set. The app opens only its own private files, so these could be removed in the app manifest with tools:node="remove" after testing.
- Vendored code has no recorded provenance: monocypher.c reports version __git__ and no commit or checksum is recorded. Add a manifest of upstream versions and hashes for sqlite, monocypher and nlohmann so future updates can be reviewed.
- WebSocket::connect does not verify Sec-WebSocket-Accept. Verify it for protocol correctness; this adds no gateway authentication.
- app/android/app/build.gradle.kts:47 signs release builds with the debug key (template TODO). Set up a real signing config before distributing any APK, because update trust then rests on an unprotected local keystore.
- app/lib/core/backend.dart:53 honours SYNC_CORE_LIB in all builds. This needs control of the same user's environment, so it crosses no boundary, but it could be limited to test builds.
- app/lib/main.dart:85 saves the server URL before validating it. An invalid URL makes every start fail, and the error screen has only a retry, so the user cannot correct it without clearing app data. Validate with the core's ws:// rule before writing.
- app/lib/screens/message_bubble.dart:468 downloads and decodes images automatically when the bubble renders, and no check for request-state chats appears in _ImageBubble. Consider tap-to-load for senders not yet accepted.
- app/lib/screens/settings.dart:232 copies the recovery key to the clipboard with no automatic clearing, and the screen does not block screenshots or recents thumbnails. Both are user-initiated and the UI warns about the clipboard, but clearing after a timeout and FLAG_SECURE on this screen would reduce exposure of an account-equivalent secret.
- deliverLoop caches sender records for the life of a connection (hub.go:507), so a key or profile change by a sender is not reflected in later frames on that connection. Clients verify box_sig, so this is staleness rather than a trust failure.
- gateway/go.mod declares go 1.25.0 and has a pre-release indirect module (go.yaml.in/yaml/v4 v4.0.0-rc.2). Known-CVE status was not checked because that needs network access; run govulncheck in an owner-controlled environment.
- get_stories reads kind, media_id and key from peer content with typed value() calls after the reply is sent, so a malformed story ends the download loop and produces a second reply for the same @extra. Validate story content on receipt in on_story.
- get_stories retries failed downloads on every refresh and spawn() starts one thread per download with no concurrency limit (core/src/client.cpp:129, 1370). A contact with many image stories can cause many concurrent threads and bodies in memory. Not stress tested, by assignment rule.
- handleSend reads the target connection before Enqueue (hub.go:468, hub.go:480-491). If the recipient reconnects between those steps, the wake goes to the old connection and the new deliverLoop can miss the row until a later wake or reconnect. This is delayed delivery rather than loss, and it comes from source review only, not from a reproduced race.
- http_request checks in.size() < 12 instead of the header length before atoi(h.c_str() + 9). Check h.size() and parse the status line strictly.
- http_request finds content-length with a substring search over all headers, so a header such as x-content-length also matches. Parse header names exactly.
- json.Unmarshal runs before Conn.allow (hub.go:272-275), so frames over the rate limit still cost a full parse.
- on_vote accepts any integer option on any message kind (core/src/client.cpp:718). The app only inflates the displayed total, per message_bubble.dart:710-711.
- random_bytes uses buffered stdio on /dev/urandom (core/src/crypto.cpp:103), which can leave key bytes in a freed stdio buffer; a direct read or getrandom avoids this.
- read_available appends to in_ without parsing while recv keeps returning full 64 KiB reads. Add an explicit cap on in_ based on kMaxFrame plus header size so the bound does not depend on timing.
- srv in gateway/main.go sets only ReadHeaderTimeout. With no ReadTimeout, WriteTimeout, IdleTimeout or connection cap, slow uploads, slow GET /media downloads and idle connections hold resources for their duration. See the uncovered entry.
- wake() writes to a blocking pipe, so sync_client_send could block if the pipe fills during a long worker stall, despite the header's non-blocking contract. Set O_NONBLOCK on the write end.
- ws.SetReadLimit allows 8 MiB before authentication (hub.go:242), though the auth frame needs under 1 KiB. A small pre-auth limit would remove that buffering. Exposure per connection ends at the 10 s auth deadline.

## Coverage

Units: 5 covered, 13 with candidates, 0 blocked, 7 deferred. The final critic proposed seven further units, recorded as deferred by the quick profile, so no clean-coverage claim is made:

- app/lib/core/models.dart#Message and Story field casts (Injection): Reported in uncovered.json and outside the existing Injection unit, which covers OS-action sinks only. valid_content checks only media_id and key for media, on_story checks only that content is an object, and ts is capped only from above with std::min. Dart casts of those fields were not traced to a rendering outcome. Flutter is unavailable in the sandbox, so this is source review only.
- core/src/client.cpp#dispatch (Business logic): Missing lifecycle modes on the sender and local-state side. No unit examines dispatch transitions: the wildcard unit covers FFI ownership and threading, and lifecycle checks covered only received media and replayed envelopes. From source, publish_story and get_stories have no blocked filter, setBlocked, leaveGroup and update_group do not touch queued outbox rows, and deleteChat removes neither outbox rows nor stories. In extras.dart, _finish deletes a recording only when it is not sent, and that file appears in no unit's reviewed_paths. Whether block, removal and delete semantics hold across these paths has not been assessed.
- core/src/client.cpp#flush_outbox (Resource and file handling): Selected companion classes without a unit on the client side. Poison-record and Retry storm are selected by no unit, and client-side Unbounded buffering is selected only for http_request. flush_outbox reads the oldest 500 rows, and rows refused with an error other than unknown_user or lacking a key stay in place, so whether one unreachable recipient can block later rows for others is unexamined. Stranger-created chats and message rows have no visible count or byte cap, and on_group calls fetch_key_then_flush per member. Existing candidates cover only the media cache, JSON nesting and HTTP body size.
- core/src/client.cpp#handle_frame (Business logic): architecture.md lists handle_frame and remember_user as entry surfaces from the untrusted gateway, but gateway-to-core units cover only net.cpp framing and http_request. The crypto unit checked only sender relabelling and unsigned box keys. Unchecked paths: the flush_outbox reply callback deletes outbox rows and marks messages sent based on gateway ok or unknown_user answers; the ready frame overwrites username and display_name meta; handle_envelope calls remember_user on m["sender"] without comparing its id to from, and that call overwrites unsigned username and display_name; searchUsers results also reach remember_user. Whether these go beyond the README key-directory limit has not been assessed.
- core/src/client.cpp#on_receipt, on_vote, on_leave, on_typing, on_story (Access control): Unchecked parallel paths. architecture.md enumerates these peer handlers, but the handle_envelope unit's sender-authority check exercised only edit, delete, react and msg replay. on_vote and on_leave succession appear only as hardening notes, and on_receipt and on_typing have no recorded check. on_story was checked for path traversal and local_path, not for sender authority. chat_of checks membership but not chats.state, so on_react, on_vote and on_receipt in request or left chats, including per-item authorization across the on_receipt mids loop, were not assessed.
- gateway/hub.go#handleProfile (Business logic): The profile frame is an unmapped entry point apart from one serveWS check that a body id cannot select another user. SetProfile deletes the old username key when a user renames, so a released name can be claimed by another identity, and handleProfile limits display_name only by trimming and rune count. No unit examined this impersonation boundary. people.dart, lists.dart and chat_info.dart, which hold username search results and the safety-number screen that README names as the control against a lying gateway, appear in no unit's reviewed_paths.
- gateway/main.go#http.Server (Resource and file handling): Reported in uncovered.json and owned by no unit. main.go sets only ReadHeaderTimeout on http.Server, with no connection cap. serveWS starts a writePump goroutine and allows an 8 MiB read limit before authentication. GET /media/{id} is unauthenticated and uses http.ServeFile. The read paths (search, user, watch with up to 5000 ids, market_list) were not assessed for query amplification; the handleSend unit's selected blocks cover buffering, pre-auth and quota for the send path, and the chained unit reported only the PostListing scan.

Cloud and deployment review was excluded because no deployment manifest existed. A later run should cover the chosen deployment and these deferred units.
