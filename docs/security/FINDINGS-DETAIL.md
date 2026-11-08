# Finding details

## Replayed envelopes revert edits, remove re-added members and restore deleted chats

`core/client.cpp:envelope-replay-no-freshness`

**Trace**
1. `core/src/client.cpp:265` `Client::handle_frame` (entrypoint): A gateway msg frame is accepted; its seq is used only for the ack.
2. `core/src/client.cpp:619` `Client::handle_envelope` (propagation): open() authenticates the replayed blob because the key depends only on identities and the ephemeral key carried in the blob.
3. `core/src/crypto.cpp:197` `sync_core::open` (propagation): There is no replay state or timestamp check.
4. `core/src/client.cpp:684` `Client::on_edit` (sink): The stale text overwrites the newer body and edited stays 1.

**Evidence**
- `core/src/client.cpp:783`: on_leave checks only current membership, so an old leave applies after a re-add at a higher group version.
- `core/src/client.cpp:754`: The version check runs only when the chat exists, so deleteChat resets replay protection for group updates.
- `core/src/client.cpp:1092`: deleteChat removes rows with no tombstone, which also removes the mid dedup at line 664.
- `gateway/store.go:257`: An honest gateway deletes the queued frame on ack, so replay is a malicious relay or injector action and not normal redelivery.
- `README.md:68`: Known limits do not list replay or stale state acceptance.

**Principal:** Untrusted relay holding previously relayed ciphertext frames, using dummy identities only.

**Input**
- `edit frames for {k:edit,mid:<m>,text:'v2 superseded'} then 'v3 current', then the v2 frame again`
- `{k:leave,conv:<g>} frame, group ver 2 re-adding the member, then the leave frame again`
- `group ver 1 frame and msg frame redelivered after deleteChat`

**Steps**
1. Build the real client.cpp into a harness in the offline sandbox, with a dummy local key and no gateway.
2. Seal each payload with dummy identities into a {t:msg,seq,from,blob,sender} frame, and pass the same frame string to handle_frame in the sequence given, reading state after each step.

**Observed:** Text returned to 'v2 superseded' after 'v3 current'. The member count went 0 after the leave, 1 after the ver 2 re-add, and 0 after the replayed leave, and the member's next group message stored 0 rows. The deleted group's rows went 0 then 1 with state 'request'. The deleted direct message's rows went 0 then 1 with text 'once'. Controls: replaying a msg with no intervening delete left one row, and replaying a group frame with the chat present changed nothing. Recorded in agents/verifier-peer/artifacts/evidence/verifier-peer-handlers.txt.

**Conditions**
- The attacker operates the gateway or can otherwise inject frames on the client connection; no peer key is needed.
- The attacker retained an earlier sealed frame, and the target state has since moved on (later edit, re-add, or chat deletion).

**Remediation:** Add a per-sender monotonic counter inside the sealed payload, or persist a replay cache of envelope ids, and reject values already seen, with state that survives deleteChat. Give edits a per-message revision and leaves the group version they apply to, and keep tombstones for deleted chats and mids. Regression: repeat each replay sequence and assert state does not change.

## Non-string text in stored peer media content makes whole message/chat-list reads throw

`core/client.cpp:message_json-reply-preview-type-error`

**Trace**
1. `core/src/client.cpp:646` `Client::on_msg` (entrypoint): valid_content accepts image/file content carrying an extra non-string text field.
2. `core/src/client.cpp:660` `Client::on_msg` (propagation): The peer-chosen reply_to is stored unvalidated; the row is inserted at 663 and set as last_message at 665.
3. `core/src/client.cpp:503` `Client::message_json` (propagation): body.value("text","") reads the replied-to message's field as a string and throws type_error.302 on a non-string.
4. `core/src/client.cpp:552` `Client::chat_json` (sink): last_message is built with message_json, so getChats at 971 (and getMessages at 983) fails as a whole.

**Evidence**
- `core/src/client.cpp:65`: image/file branch of valid_content checks only media_id and key, not text.
- `core/src/client.cpp:664`: db_.changes() guard; row is already stored and last_message set before message_json runs at 666, so a throw there is caught/acked and the poison persists.
- `core/src/client.cpp:983`: getMessages calls message_json for each row with no per-row guard.
- `app/lib/core/app_state.dart:43`: Future.wait over main/archived/requests fails if any one filter fails.
- `app/lib/core/app_state.dart:38`: loaded is set only after refreshChats and refreshStories complete.
- `app/lib/main.dart:108`: The splash screen stays up while loaded is false.

**Principal:** A registered Sync user who can send the victim a first message.

**Input**
- `{"k":"msg","mid":"<32hex>","kind":"image","reply_to":"<same 32hex>","content":{"media_id":"<32hex>","key":"<64hex>","text":123}}`

**Steps**
1. Seal and send the payload to the victim; on_msg stores it (text:123 passes valid_content), sets it as last_message, then the initial message_json(mid) throws and is caught/acked.
2. Call getChats for any filter whose chat has this as last_message (e.g. 'requests' for a first contact): chat_json->message_json(last) throws, handle_request returns {@type:error} for the whole request.
3. Call getMessages for that chat: the loop at :983 throws on the poison row and the whole reply fails.

**Observed:** Local harness: body.value("text","") on {media_id,key,text:123} throws [json.exception.type_error.302] type must be string, but is number (identical for an array). See artifact native-robustness-repro.txt (T2). The request-level and app-level consequences are source-derived from the unguarded loops and handle_request catch.

**Conditions**
- Any registered peer, including an unaccepted first contact (chat enters the 'request' state, selected by the requests filter).
- The poison message persists as the chat's last_message after the initial on_msg throw is caught and acked.
- The whole-app splash-screen lockup additionally depends on Flutter behaviour (Future.wait propagation), confirmed only by source, not run.

**Remediation:** Read the preview tolerantly and isolate per-row failures: use body.contains("text") && body["text"].is_string() before reading, and wrap the per-row message_json call in getChats/getMessages in try/catch so one bad row is skipped instead of failing the list. Optionally reject unknown/mistyped content fields in valid_content.

## Peer-supplied JSON nesting depth is unbounded before a recursive copy on the worker thread, crashing the client in a redelivery loop

`core/client.cpp:peer-json-unbounded-nesting`

**Trace**
1. `core/src/client.cpp:265` `Client::handle_frame` (entrypoint): A msg frame reaches handle_envelope; the ack at line 273 is sent only after it returns.
2. `core/src/client.cpp:627` `Client::handle_envelope` (propagation): Decrypted peer plaintext is parsed with no depth limit.
3. `core/src/client.cpp:645` `Client::on_msg` (sink): `J content = p.at("content")` copies the peer value with the recursive copy constructor, before valid_content runs.

**Evidence**
- `core/third_party/nlohmann/json.hpp:20447`: basic_json copy constructor, which recursively copies nested containers (reproduced to SIGSEGV at ~1e6 depth).
- `core/third_party/nlohmann/json.hpp:19870`: Destruction flattens to a heap-allocated stack, so the library avoids recursion there but not in the copy path.
- `core/src/client.cpp:813`: on_story makes the same recursive copy after its contact check.
- `gateway/hub.go:26`: maxFrameBytes is the only size limit on this path, 8 MiB; it does not bound nesting.
- `gateway/hub.go:504`: deliverLoop: rows stay on disk until acked and are redelivered on the next connection.

**Principal:** A registered Sync user who has the victim's 64-hex id and box_pk (obtainable via directory search).

**Input**
- `{"k":"msg","mid":"<32hex>","kind":"image","content":[[[[ ... ~1e6 levels ... ]]]]}`

**Steps**
1. Seal the above payload to the victim's box key and send it as a `send` frame to the gateway for the victim's id.
2. On the victim's next connection the gateway delivers it; handle_envelope parses it, on_msg copies `content`, the recursive copy overflows the worker stack.
3. Because the ack is sent only after handle_envelope returns, the row is never acked and is redelivered on every reconnect.

**Observed:** Local harness: J::parse of a 2,000,000-byte 1e6-deep nest succeeds, then the copy `J c = j;` crashes with Segmentation fault (core dumped), exit 139. See artifact native-robustness-repro.txt (T1).

**Conditions**
- Any registered user who knows the victim's user id can send a first-contact envelope; the victim need not accept.
- The gateway retains the unacked poisoned row and redelivers it on each reconnect, making the crash persistent.

**Remediation:** Bound peer JSON depth before any recursive operation: parse decrypted peer bytes with a SAX/callback parser that rejects documents deeper than a small fixed limit (and reject over-limit before copying content), then drop-and-ack such envelopes as handle_frame already does for exceptions.

## Exceptions in posted completion jobs and helper threads are uncontained and abort the process

`core/client.cpp:unguarded-posted-jobs-and-helper-threads`

**Trace**
1. `core/src/client.cpp:855` `Client::upload_file helper` (entrypoint): The gateway's HTTP upload response is received on a helper thread.
2. `core/src/client.cpp:858` `Client::upload_file helper` (propagation): j.value("id","") throws type_error.302 if id is present but not a string.
3. `core/src/client.cpp:135` `Client::spawn` (sink): The helper body runs with no handler, so the exception leaves the thread function and calls std::terminate.

**Evidence**
- `core/src/client.cpp:161`: run() executes posted jobs with no try/catch (worker thread function).
- `core/src/client.cpp:889`: download_to posts its completion back to the worker, outside any handler.
- `core/src/client.cpp:1233`: The downloadMedia completion calls emit_message, which reaches message_json and can throw.
- `core/src/client.cpp:907`: Comparison control: handle_request wraps dispatch in try/catch, which the job loop and helper body lack.

**Principal:** Path (1): an attacker controlling or MITMing the plain-ws gateway. Path (2): any registered peer who can send the victim a media message.

**Input**
- `Path (1) gateway HTTP upload response body: {"id":123}`
- `Path (2) envelope: {"k":"msg","mid":"<32hex>","kind":"image","reply_to":"<same 32hex>","content":{"media_id":"<32hex>","key":"<64hex>","text":123}}`

**Steps**
1. Path (1): when the victim sends media, return {"id":123} as the POST /media response body; upload_file's helper calls value("id",""), which throws inside spawn() with no handler.
2. Path (2): plant the poison media message; when the victim taps download, download_to's completion job calls emit_message->message_json, which throws in run()'s unguarded job loop.
3. Either way the escaping exception calls std::terminate and aborts the process.

**Observed:** Local harness: an exception escaping a std::thread body prints 'terminate called after throwing ... std::runtime_error' and aborts with SIGABRT (exit 134); value("id","") on {"id":123} throws type_error.302. See artifact native-robustness-repro.txt (T3, T2).

**Conditions**
- Path (1): a hostile or man-in-the-middle gateway (README documents no TLS) returns a non-string `id` in the media upload response.
- Path (2): a peer sends a self-replying media message with non-string text, and the victim taps download on it.
- Path (2) requires only a registered peer to plant the poison media message.

**Remediation:** Wrap the worker job loop and the spawn() helper body in try/catch and route failures to the originating request's error path (or a logged drop), so untrusted input cannot abort the process.

## AI rate limit follows a free self-generated key, so operator spend has no per-actor or aggregate budget

`gateway/ai.go:AIService.allow:per-key-spend-limit`

**Trace**
1. `gateway/hub.go:386` `Conn.handle` (entrypoint): An authenticated 'ai' frame is dispatched to handleAI.
2. `gateway/store.go:97` `Store.UpsertIdentity` (propagation): Any key with a valid self-signature becomes a user on first auth, with no cost or admission control.
3. `gateway/ai.go:171` `Conn.handleAI` (propagation): The limit is checked for c.id only.
4. `gateway/ai.go:178` `Conn.handleAI` (propagation): The request context derives from context.Background, so a disconnect does not cancel it.
5. `gateway/ai.go:125` `AIService.Reply` (sink): A paid provider call is made with the operator's key and MaxTokens 16000.

**Evidence**
- `gateway/ai.go:64`: allow tracks hits per user string and has no aggregate counter.
- `gateway/ai.go:23`: aiConcurrency 16 is the only service-wide control, and it limits parallelism rather than volume.
- `gateway/ai.go:43`: The hits map keeps an entry per key and no code removes keys, so it also grows with each key used.
- `gateway/ai.go:121`: A caller that cannot get a slot waits until its context ends and then returns ai_busy.

**Principal:** A client that generates several Ed25519 keys and authenticates each one to a local test gateway with a mocked provider.

**Input**
- `{"t":"ai","rid":"r","turns":[{"role":"user","text":"hi"}]} sent 25 times per identity, for 3 identities`
- `The same frame sent 16 times from one identity against a mock that holds each request, then once from a second identity`

**Steps**
1. Start the gateway handlers in-process with NewAIService pointed at a local mock provider and retries disabled.
2. Log in 3 fresh identities and send 25 ai frames from each, counting replies and mock calls.
3. Separately, send one ai frame, close the client socket while the mock is waiting, and record whether the mock request context was cancelled.
4. Separately, hold 16 mock requests from one identity, send one frame from a second identity, wait 3 s, and record the mock's call count and whether a reply arrived; then release the mock.

**Observed:** Independently reproduced. Each identity got ok=20 and rate_limited=5. The mock recorded upstream_calls=60 against per_user_limit=20, with max_tokens=16000 in the request. upstream_cancelled_after_client_disconnect=false. With one key holding 16 calls, the second identity's call did not reach the mock and got no reply within 3 s; it reached the mock only after release (upstream_total=17). The 2-minute ai_busy expiry follows from source and was not waited out. No real provider was contacted, so real spend and real slot hold times were not measured.

**Conditions**
- ANTHROPIC_API_KEY is set on the gateway; otherwise the feature reports ai_not_configured.
- The attacker needs only a self-generated identity.
- Actual cost depends on provider pricing and any account spend limit, neither of which is visible in the repository. How long real calls hold a slot depends on the provider.

**Remediation:** Add a service-wide request and token budget per minute and per day checked before the upstream call, consider admission control for AI use since keys are free, derive the request context from the connection's done channel, cap the slots one identity can hold, and evict idle entries from hits. Regression cases: N identities together cannot exceed the global budget, one identity cannot hold every slot, and closing the connection cancels the upstream request.

## Each marketplace post decodes every listing under the database write lock, and the listing cap is per free key

`gateway/market.go:PostListing:full-scan-under-write-lock`

**Trace**
1. `gateway/market.go:151` `Conn.handleMarket` (entrypoint): market_post is accepted from any authenticated identity.
2. `gateway/market.go:47` `Store.PostListing` (propagation): A write transaction is opened, taking the single bbolt writer lock.
3. `gateway/market.go:50` `Store.PostListing` (sink): Every listing is decoded while the lock is held.

**Evidence**
- `gateway/market.go:19`: maxSellerListing of 20 is per seller key, with no total limit.
- `gateway/market.go:63`: The cap is checked only after the full scan, so refused posts cost the same lock hold.
- `gateway/market.go:102`: Listings decodes the whole bucket on each market_list, although at most 100 results are returned.
- `gateway/store.go:206`: Enqueue writes through the same database, so it waits on the same writer lock.

**Principal:** Dummy sellers on a local test gateway, with the bucket seeded directly at small sizes to measure growth and the shared stall.

**Input**
- `{"t":"market_post","title":"x","price":"1","description":"<2000 characters>"} sent 21 times from one key and once from a second key`
- `Direct seeding of 2000, 8000 and 16000 listings of about 2 KiB across seller ids of 20 listings each, followed by one refused post and one Listings call at each size`
- `{"t":"market_post","rid":"r","title":"x","price":"1"} looped from 4 connections whose keys are at the cap, while a separate identity sends {"t":"send","to":"<online id>","blob":"QQ=="}`

**Steps**
1. Post 20 listings from one key, then a 21st, then one from a new key.
2. Seed the bucket to each size and time one refused post and one list.
3. At 16000 listings, time 30 sends with no market traffic.
4. Bring 4 further identities to their cap, have each loop refused posts one at a time, and time 30 sends again.

**Observed:** Independently reproduced, and the shared stall the hunter inferred was measured. same_key_21st=too_many_listings, other_key_first_ok=true. Refused post time was 33.8 ms at 2000 listings, 125.3 ms at 8000 and 222.9 ms at 16000; list time was 34.3 ms, 123.8 ms and 257.1 ms. At 16000 listings, send latency was p50=13.4 ms, max=14 ms when idle and p50=823 ms, max=938 ms under refused posts, with attacker_posts=250 in 24.9 s, far below the frame rate limit. Listings were seeded directly, so the time to create them through the protocol was not measured, and larger populations and more connections were not run.

**Conditions**
- The attacker needs only self-generated identities, one per 20 listings.
- The stall grows with the listing count. Listings persist for up to the 30-day TTL. 16000 listings need 800 identities.

**Remediation:** Keep a per-seller counter or index in the same transaction so a post is constant time and a refusal needs no scan, add an aggregate listing cap or admission control, limit posts per identity, and move expiry to a background sweep. Regression cases: post time does not grow with the number of other sellers' listings, refused posts do not delay concurrent sends, and posts over the aggregate cap are refused.

## Media uploads have no per-identity or aggregate byte quota, and blobs persist for 30 days in the shared data directory

`gateway/media.go:Save:no-aggregate-byte-quota`

**Trace**
1. `gateway/hub.go:385` `Conn.handle` (entrypoint): media_token issues a token to any authenticated identity with no limit beyond the frame rate.
2. `gateway/hub.go:69` `Hub.uploadMedia` (propagation): The upload handler checks only the token's validity.
3. `gateway/media.go:55` `MediaStore.CheckToken` (propagation): Signature and expiry are checked; the user field is not read and the token is not single-use.
4. `gateway/media.go:109` `MediaStore.Save` (sink): The blob is renamed into permanent storage under a new id with no accounting.

**Evidence**
- `gateway/media.go:20`: maxMediaBytes is a per-blob cap only.
- `gateway/main.go:19`: The default media TTL is 30 days.
- `gateway/main.go:28`: The media store uses the same data directory that OpenStore uses at main.go:22, so they share a volume by default.
- `gateway/media.go:134`: Cleanup is the only removal path and acts only on age.

**Principal:** An authenticated dummy identity uploading to a local test gateway.

**Input**
- `POST /media with Authorization: Bearer <one token> and a 1 MiB body, repeated 8 times, then 3 more uploads with newly issued tokens`
- `POST /media with a 1 MiB body repeated until refused, with the data directory on a private 32 MiB tmpfs, followed by {"t":"send","to":"<offline id>","blob":"<32 KiB>"} repeated 400 times`

**Steps**
1. Log in one identity to an in-process gateway and request one media_token.
2. Upload 8 blobs of 1 MiB with that same token and 3 more with new tokens.
3. Count files and bytes in the media directory, then test expired, tampered and absent tokens.
4. Separately, run the gateway with its data directory on a private 32 MiB tmpfs mount inside the sandbox, upload until refused, then send 400 queued frames.
5. Delete the media files and send one more frame.

**Observed:** Independently reproduced. uploads_accepted=11, files=11, bytes_on_disk=11534336, per_blob_cap=52429824; expired, tampered and absent tokens each returned 401. On the 32 MiB volume: 31 uploads accepted, the next returned 500 with ENOSPC. Of 400 sends, 23 succeeded and 377 returned server_error with enqueue ENOSPC logged. After the media files were removed, a send succeeded. The gateway process did not crash. This used a small private volume, not a production disk.

**Conditions**
- The attacker needs only a self-generated identity.
- No upstream body limit or disk quota exists in the repository; a deployment could add one or place media on a separate volume, and no deployment manifest exists in this revision.
- The attacker must upload as many bytes as the volume has free, so the required bandwidth and time scale with the disk size.

**Remediation:** Parse the user from the verified token and enforce per-identity and aggregate byte budgets before accepting bytes, keep the reservation through the upload, and refuse uploads above a free-space floor so the store keeps room to write. Regression cases: uploads beyond the identity budget return an error and leave no file, and uploads refused at the floor leave sends working.

## Recipient queue quota counts rows rather than bytes, has no expiry, and can be consumed entirely by one stranger

`gateway/store.go:Enqueue:row-count-only-recipient-quota`

**Trace**
1. `gateway/hub.go:360` `Conn.handle` (entrypoint): A send frame is accepted from any authenticated identity to any existing recipient.
2. `gateway/hub.go:275` `Hub.serveWS` (propagation): Conn.allow charges one token per frame regardless of size, using a bucket created fresh for each connection at hub.go:249.
3. `gateway/hub.go:480` `Conn.handleSend` (propagation): The blob is passed to Enqueue with only the maxQueue row limit.
4. `gateway/store.go:208` `Store.Enqueue` (propagation): The only check is the row count, which returns ErrQueueFull to every sender alike once reached.
5. `gateway/store.go:222` `Store.Enqueue` (sink): The blob is written durably with no size accounting or expiry.

**Evidence**
- `gateway/hub.go:25`: maxFrameBytes of 8 MiB limits each frame, not each stored row.
- `gateway/hub.go:26`: maxQueue of 20000 is the row limit.
- `gateway/store.go:218`: json.Marshal escapes characters such as '<' to six bytes, so the stored row can exceed the received frame.
- `gateway/store.go:251`: Ack is the only removal path, so an unacked row never leaves.
- `core/src/client.cpp:421`: The client keeps a refused message in its outbox for retry on reconnect, so queue_full delays rather than loses mail.
- `core/src/client.cpp:626`: Blocking is applied only on the client after delivery, so it does not protect the gateway quota.

**Principal:** Authenticated strangers with no relationship to the offline dummy recipient, on a local test gateway.

**Input**
- `{"t":"send","to":"<victim id>","blob":"<7 MiB of A>"} sent 3 times`
- `{"t":"send","to":"<victim id>","blob":"<1 MiB of the character '<'>"}`
- `{"t":"send","rid":"r","to":"<victim id>","blob":"QQ=="} sent from 4 identities until queue_full, then once from a third party`

**Steps**
1. Log in attacker and victim identities on an in-process gateway, then disconnect the victim.
2. Send three 7 MiB blobs and compare gateway.db size and the row count, then send the 1 MiB escaped blob and read the stored row's length.
3. On a fresh gateway, have 4 stranger identities send small frames to the offline victim until queue_full, with no prefill.
4. Send one frame from a new third-party identity. Then bring the victim online, ack 50 rows, and send from the third party again.
5. Exhaust the frame budget on one connection, reconnect the same identity, and count accepted frames, reading replies in chunks of 100.

**Observed:** Independently reproduced, and the hunter's prefill was replaced by a real fill. large_rows=3, db_bytes_before=32768, db_bytes_after=60878848. A 1048576-byte escaped blob stored as a 6291549-byte row (ratio 6.00). 4 senders got accepted=20000 and rate_limited=0 in 69 s, stored_count=20000; the third party got ok=false error=queue_full. After the victim came online and acked, the third party got ok=true. Rate check: first connection ok=408 rate_limited=1592, probe 100 of 100 limited, after reconnect ok=300 rate_limited=0. Multi-gigabyte queues were not run: a large-row fill and any per-recipient byte total remain arithmetic.

**Conditions**
- The attacker needs only a self-generated identity and the recipient's id.
- Denying a victim's mail requires the victim to be offline or draining more slowly than the attacker sends. An online client acks junk and frees the queue.
- No disk quota or upstream limit exists in the repository; deployed controls are unknown.

**Remediation:** Track queued bytes per recipient and per sender using the stored size, enforce a byte cap and a per-sender share of the recipient quota, expire undelivered rows after a retention period, and hold the rate budget per identity with a byte-based charge so reconnecting does not refill it. Regression cases: a large-blob sender hits the byte cap before the row cap, one sender at its share does not cause queue_full for another sender, and a reconnect does not restore the budget.

## Prefix search lets an identity with no known ids enumerate users and then track their presence

`gateway/store.go:SearchUsers:prefix-walk-enumerates-directory`

**Trace**
1. `gateway/hub.go:367` `Conn.handle` (entrypoint): A search frame from any identity is passed to SearchUsers.
2. `gateway/store.go:169` `Store.SearchUsers` (propagation): The cursor returns up to 20 users matching any non-empty prefix, so longer prefixes can reach the remainder.
3. `gateway/hub.go:425` `Conn.handleWatch` (propagation): Any valid id can be watched with no relationship check.
4. `gateway/hub.go:447` `Conn.handleWatch` (sink): Online state and last_seen are returned, and later changes are pushed by notifyPresence.

**Evidence**
- `README.md:80`: The documented limit is presence visible to anyone who asks for it by user id; it does not mention enumerating the ids.
- `gateway/hub.go:29`: maxWatched of 5000 is per connection, and an actor can open more connections with more keys.
- `gateway/store.go:32`: The User entry returned by search includes last_seen directly.
- `app/lib/screens/people.dart:59`: The app does not search terms shorter than 2 characters, a client-only rule the gateway does not share.
- `app/lib/main.dart:109`: A user with no username is sent to onboarding, whose Continue button requires one (onboarding.dart:142), so app users are searchable.

**Principal:** A new identity on a local test gateway that knows no user ids, against 60 dummy users.

**Input**
- `{"t":"search","q":"<prefix>"} walked recursively over a-z, 0-9 and underscore whenever a result returned 20 users`
- `{"t":"watch","ids":["<recovered ids>"]}`

**Steps**
1. Register 60 dummy users with usernames plus one identity with no username, and disconnect 30 of the 60.
2. Log in a new identity and walk prefixes, descending when a query returns the full 20 results, while staying under the frame rate.
3. Watch all recovered ids and count presence frames.
4. Disconnect one watched online user and read the next presence frame.

**Observed:** Independently reproduced with a separately generated population. population=60, recovered=60, queries=259, search rows with last_seen=30, no_username_user_found=false. Presence: online=30, offline_with_last_seen=30. When a watched user disconnected, a live presence frame arrived with that id, online=false and last_seen set. Only dummy users on the local fixture were involved, and query counts at larger populations were not measured.

**Conditions**
- The attacker needs only a self-generated identity.
- Only users who have set a username are enumerable, which the app requires during onboarding. The owner may regard the username directory itself as public, in which case the main remaining concern is bulk presence tracking.

**Remediation:** Enforce on the gateway an exact username or a long minimum prefix (the app's 2-character rule would not stop this walk), limit search per identity rather than per connection, omit last_seen from search and user results, and restrict presence to established contacts, for example with a mutual consent token. If the directory is intended to be public, update README to state that it can be enumerated in full. Regression cases: a short prefix returns nothing and a stranger's watch returns no presence.
