# Needs validation

## OS backup is not excluded for the local store, decrypted media or keystore-backed key

`app/android-manifest:auto-backup-not-disabled`

The Android manifest sets no allowBackup, fullBackupContent or dataExtractionRules, and no backup exclusion exists in the iOS app source. Source of the locked path_provider_android 2.3.1 maps application support to Context.getFilesDir(), which is the folder holding sync.db (unencrypted metadata) and media/ (decrypted media). If platform backup runs, that data leaves the private folder the README describes; message bodies and the seed stay AEAD-sealed. The attacker capability would be access to the user's backup account or backup transport, not a peer or the gateway. A restore may also separate the database from the keystore key. The locked flutter_secure_storage 11.2.0 defaults resetOnError to true, its read path deletes the value on failure and retries, and its README warns of this failure and advises disabling or excluding backup. If that happens, _localKey generates a new key. A sandboxed core run showed that reopening the same data directory with a different key makes sync_client_create return null, and the splash screen then offers only Try again, so the recovery key flow is unreachable. Whether a real backup and restore reaches either result was not observed.

**Trace**
1. `app/android/app/src/main/AndroidManifest.xml:7`: No backup attribute or rule is declared here or elsewhere in the app's Android sources, so the platform default applies.
2. `app/lib/main.dart:62`: The application support directory, which is filesDir on Android per the locked plugin source, becomes the core's data directory.
3. `core/src/client.cpp:873`: The output path for decrypted media is built under that data directory, next to sync.db; the write is at line 884.

**Blockers**
- Flutter and an Android emulator or device are unavailable, so the merged manifest and actual backup contents were not observed. The mapping of application support to filesDir is settled from plugin source and is no longer a blocker.
- Whether a restored database with a lost key reaches the lockout path depends on plugin and OS behaviour at runtime. The core refusal and the plugin's reset code are source or locally established, but an actual restore sequence was not run.
- iOS backup inclusion of Application Support, and restore of the keychain item under the plugin's default 'unlocked' accessibility, were not observed because no iOS build exists.

**Plan**
- local: On an isolated Android emulator with dummy data, inspect the merged manifest for allowBackup and backup rules, run bmgr backupnow then a restore into a clean install, list which files under the app's files directory came back, and record whether the app starts or stops at the start error. Then set allowBackup=false or add exclusion rules and repeat as the regression case. On an iOS simulator or test device with a dummy profile, check the backup state of Application Support and the keychain item's accessibility.

## Peer-chosen file bytes reach the OS default handler under a peer-chosen name

`app/message_bubble.dart:open-file-os-sniffed-peer-bytes`

Tapping a file bubble passes the decrypted peer file to the OS opener with no type and no warning, while the bubble shows a name the peer chose. The attacker capability is a peer able to send a file message, and a user tap is required. The cached file has no extension. On Linux, open_filex 5.0.0 starts xdg-open with the path and no shell, and a sandboxed probe showed xdg-mime classifying extensionless fixtures by content: text/html, application/pdf and application/x-desktop. So the peer's bytes, not the displayed name, can determine the type the Linux tooling reports, and a file shown as a PDF could open in a different handler. macOS uses the open command with the path, and the release build has the app sandbox entitlement. On Android the same call uses ACTION_VIEW with type */* for an unknown extension and a read-only grant, which limits the effect. No code execution was observed or is claimed.

**Trace**
1. `core/src/client.cpp:641`: A peer supplies a file message; valid_content (line 65) checks only media_id and key, leaving name and mime unchecked.
2. `core/src/client.cpp:873`: The decrypted peer bytes are given the path dir/media/<message id>, with no extension.
3. `app/lib/screens/message_bubble.dart:556`: A single tap calls OpenFilex.open on that path with no type and no prompt.

**Blockers**
- The handler that a real desktop session starts through xdg-open, and the behaviour of macOS open for extensionless peer content, depend on the desktop environment and its configuration and were not observed. Only xdg-mime type detection was observed, in a sandbox with no desktop session.
- Flutter is unavailable, so the tap path could not be run.
- Whether a sniffed type such as HTML or a desktop entry gives any effect beyond viewing is unknown, and no such effect is claimed.

**Plan**
- local: On an isolated Linux desktop VM and a macOS VM with dummy files, run the platform opener on extensionless copies of harmless HTML, text and desktop-entry fixtures, and record which handler starts and whether anything runs without a further prompt. If the handler differs from the label, add a confirmation showing the detected type, and test that a mislabelled file triggers it.

## Local database is created readable by other OS users on Linux desktop

`core/db.cpp:local-store-default-file-mode`

On Linux, which has no per-app sandbox, the core creates sync.db and its WAL and SHM files with default permissions. An independent sandboxed run with umask 022 and a harness-created 0755 data directory gave mode 0644 for all three, and 0700 for media/. They contain unencrypted metadata: chat ids, sender ids, timestamps, usernames and display names. The attacker capability is another local OS user account, and the operation would be reading that metadata, if the parent directories can be traversed. The README documents this metadata as unencrypted at rest but does not state that it is readable by other users. Message bodies and the seed stay encrypted, and the media directory blocks access to the plaintext files inside it.

**Trace**
1. `app/lib/main.dart:63`: The application support directory is created with no explicit mode and passed to the core. This is the local-store creation path; the lower-trust principal is another OS user reading the result, not a caller of this code.
2. `core/src/client.cpp:72`: The database path is built from that directory.
3. `core/src/db.cpp:91`: sqlite3_open creates the store with default modes, and no chmod or umask call exists in core/src.

**Blockers**
- The target Linux home directory mode decides reachability: a 0700 or 0750 home blocks unrelated users, and this was not established for the supported distributions. The audit host's own home is 0700, which would block the read there.
- Flutter is unavailable, so the mode of the directory created by path_provider_linux and Dart at ~/.local/share/uz.sync.sync_app was not observed. Only the core's file modes were run, with the data directory created by the harness.

**Plan**
- local: Build the Linux app on an isolated machine with a dummy profile, run stat on ~/.local/share/uz.sync.sync_app and its files, and read sync.db as a second dummy user under a 0755 home. The regression case is that the data directory is 0700 and the database files 0600 at creation.
- deployment: The owner confirms which Linux distributions and home directory modes are supported, and whether multi-user Linux hosts are in scope.

## Media HTTP responses are buffered in memory with no size limit or overall deadline

`core/net.cpp:http_request-unbounded-response-body`

http_request appends every received byte to a vector until the peer closes the connection (net.cpp:272-284), with no running size check; the Content-Length comparison runs only after the whole body is buffered (net.cpp:299). The sibling WebSocket path enforces kMaxFrame and uploads enforce kMaxMedia, but the download path has no equivalent cap. SO_RCVTIMEO (net.cpp:83) bounds each recv to 30s, not the whole transfer, so a slow sender can also hold a helper thread open, and ~Client waits for helpers. The honest gateway caps media at 50 MiB on upload (gateway/media.go:96-104), so an honest server's downloads are bounded; the exposure is a hostile or MITM gateway (README:70 documents no TLS) driving unbounded memory growth in the client. get_stories starts image downloads during a list refresh (client.cpp:1370), so this runs without a per-item user action. The impact is limited to the victim's own client device. Source confirms there is no client-side size bound and no total deadline; the decisive unobserved fact is whether this yields a meaningful denial of service on a real device.

**Trace**
1. `core/src/client.cpp:876`: GET /media/<id> is issued to the gateway on a helper thread.
2. `core/src/net.cpp:275`: recv repeats until the connection closes, with no byte count or total deadline.
3. `core/src/net.cpp:283`: in.insert grows the response buffer without a limit.

**Blockers**
- The real client memory growth and failure mode on a target device, and whether this amounts to a meaningful denial of service (the blast radius is a single client, not a shared service), were not observed; by the resource-exhaustion rules this needs a demonstrated meaningful impact, not availability alone.
- Device memory limits and how the mobile OS terminates the app under memory pressure (and recovery) are outside the repository.

**Plan**
- local: In the sandbox, link core net.cpp (with crypto.cpp + vendored monocypher) into a harness, start a loopback stub server that returns `HTTP/1.1 200 OK` with a large body (e.g. 200 MiB, far above kMaxMedia), point http_request at 127.0.0.1, and assert that res.body.size() reaches the full oversized length (demonstrating no cap). Then add a running size cap (kMaxMedia + AEAD overhead) and a total-transfer deadline and confirm the read aborts with an error at the cap.
- deployment: On a test device, point the app at an owner-controlled test gateway that returns an oversized media/story response and observe whether app memory grows unbounded, whether the OS kills the app, and how it recovers; confirm the fix fails such a response with a bounded error and stable memory.
