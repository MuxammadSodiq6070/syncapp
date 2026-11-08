// Helper threads may handshake at the same time, and the PSA RNG is process-global.
#define MBEDTLS_THREADING_C
#define MBEDTLS_THREADING_PTHREAD
