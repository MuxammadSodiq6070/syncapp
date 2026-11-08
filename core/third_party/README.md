# Vendored code

Compiled from these folders, with no download at build time. Update by replacing the
folder and this table together.

| Folder | Version | Source |
|---|---|---|
| monocypher | 4.0.2 | github.com/LoupVaillant/Monocypher, tag 4.0.2 |
| sqlite | 3.51.0 | sqlite.org amalgamation, 3510000 |
| nlohmann | 3.11.3 | github.com/nlohmann/json, tag v3.11.3, single header |
| mbedtls | 3.6.5 | github.com/Mbed-TLS/mbedtls release tarball, sha256 4a11f1777bb95bf4ad96721cac945a26e04bf19f57d905f241fe77ebeddf46d8; tests, programs, docs removed |

`core/src/ca_bundle.cpp` holds the Mozilla CA roots from curl.se/ca/cacert.pem. Refresh it
with each app release, because a root that changes after the app ships cannot be trusted
until users update.
