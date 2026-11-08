/* sync_core public C API (TDLib-style JSON client).
 *
 * The client owns one worker thread holding the network connection, E2EE keys
 * and the local database. Requests go in as JSON with sync_client_send; replies
 * and live updates come out through sync_client_receive. Requests carrying an
 * "@extra" field get it echoed on the reply.
 */
#ifndef SYNC_CORE_H
#define SYNC_CORE_H

#ifdef __cplusplus
extern "C" {
#endif

#if defined(__GNUC__) || defined(__clang__)
#define SYNC_API __attribute__((visibility("default"))) __attribute__((used))
#else
#define SYNC_API
#endif

/* data_dir: writable folder for the database and media cache.
 * local_key_hex: 32-byte hex key from the platform keystore; encrypts the identity
 *                and message bodies at rest.
 * gateway_url: ws://host:port. Returns NULL on failure. */
SYNC_API void *sync_client_create(const char *data_dir, const char *local_key_hex,
                                  const char *gateway_url);

/* Thread-safe and non-blocking. */
SYNC_API void sync_client_send(void *client, const char *json);

/* Blocks up to timeout_seconds. Returns a heap string to release with
 * sync_string_free, or NULL on timeout. */
SYNC_API char *sync_client_receive(void *client, double timeout_seconds);

SYNC_API void sync_string_free(char *s);

/* Stops the worker. No other call may be in progress on this client. */
SYNC_API void sync_client_destroy(void *client);

#ifdef __cplusplus
}
#endif
#endif
