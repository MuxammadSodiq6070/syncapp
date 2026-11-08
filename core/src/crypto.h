// E2EE primitives: X25519 + XChaCha20-Poly1305 + BLAKE2b, Ed25519 identities.
#pragma once
#include <array>
#include <cstdint>
#include <optional>
#include <string>
#include <vector>

namespace sync_core {

using Bytes = std::vector<uint8_t>;
using Key32 = std::array<uint8_t, 32>;

std::string to_hex(const uint8_t *p, size_t n);
inline std::string to_hex(const Bytes &b) { return to_hex(b.data(), b.size()); }
inline std::string to_hex(const Key32 &k) { return to_hex(k.data(), k.size()); }
std::optional<Bytes> from_hex(const std::string &s);
std::optional<Key32> key_from_hex(const std::string &s);
std::string b64_encode(const Bytes &b);
std::optional<Bytes> b64_decode(const std::string &s);
Bytes str_bytes(const std::string &s);
std::string bytes_str(const Bytes &b);

void random_bytes(uint8_t *p, size_t n);
std::string random_id();  // 128-bit hex
void wipe(void *p, size_t n);

struct Identity {
  Key32 seed{};
  std::array<uint8_t, 64> sign_sk{};
  Key32 sign_pk{};
  Key32 box_sk{};
  Key32 box_pk{};

  static Identity from_seed(const Key32 &seed);
  std::string id() const { return to_hex(sign_pk); }
  Bytes sign(const Bytes &msg) const;
  // Signature binding the X25519 key to the Ed25519 identity.
  Bytes box_signature() const;
};

bool verify_signature(const Key32 &sign_pk, const Bytes &msg, const Bytes &sig);
// True when box_sig proves user_id (an Ed25519 key) owns box_pk.
bool verify_box_key(const std::string &user_id, const Key32 &box_pk, const Bytes &box_sig);

// One-shot authenticated encryption from sender to recipient. A fresh ephemeral
// key gives sender-side forward secrecy; the static-static DH authenticates the
// sender. Layout: version(1) | ephemeral_pk(32) | nonce(24) | mac(16) | ciphertext.
Bytes seal(const Identity &me, const std::string &to_id, const Key32 &to_box_pk,
           const Bytes &plaintext);
std::optional<Bytes> open(const Identity &me, const std::string &from_id,
                          const Key32 &from_box_pk, const Bytes &envelope);

// Symmetric encryption, used for local data and media. Layout: nonce | mac | ciphertext.
Bytes aead_seal(const Key32 &key, const Bytes &plaintext, const std::string &ad = "");
std::optional<Bytes> aead_open(const Key32 &key, const Bytes &sealed, const std::string &ad = "");

// Group ids commit to their creator, so nobody else can claim an id first.
std::string group_id_for(const std::string &creator_id, const std::string &salt);

// Hash of both identities, identical on both sides: compared out of band to detect
// a gateway swapping users behind a username.
std::string safety_number(const std::string &a_id, const std::string &b_id);

}  // namespace sync_core
