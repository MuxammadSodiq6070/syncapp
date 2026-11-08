#include "crypto.h"

#include <cstdio>
#include <cstring>
#include <stdexcept>

extern "C" {
#include "monocypher-ed25519.h"
#include "monocypher.h"
}

#include <fcntl.h>
#include <stdlib.h>
#include <unistd.h>

#include <cerrno>

namespace sync_core {

std::string to_hex(const uint8_t *p, size_t n) {
  static const char *d = "0123456789abcdef";
  std::string s(n * 2, '0');
  for (size_t i = 0; i < n; i++) {
    s[i * 2] = d[p[i] >> 4];
    s[i * 2 + 1] = d[p[i] & 15];
  }
  return s;
}

static int hexval(char c) {
  if (c >= '0' && c <= '9') return c - '0';
  if (c >= 'a' && c <= 'f') return c - 'a' + 10;
  if (c >= 'A' && c <= 'F') return c - 'A' + 10;
  return -1;
}

std::optional<Bytes> from_hex(const std::string &s) {
  if (s.size() % 2) return std::nullopt;
  Bytes out(s.size() / 2);
  for (size_t i = 0; i < out.size(); i++) {
    int a = hexval(s[i * 2]), b = hexval(s[i * 2 + 1]);
    if (a < 0 || b < 0) return std::nullopt;
    out[i] = uint8_t(a << 4 | b);
  }
  return out;
}

std::optional<Key32> key_from_hex(const std::string &s) {
  auto b = from_hex(s);
  if (!b || b->size() != 32) return std::nullopt;
  Key32 k;
  std::memcpy(k.data(), b->data(), 32);
  return k;
}

static const char kB64[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

std::string b64_encode(const Bytes &b) {
  std::string o;
  o.reserve((b.size() + 2) / 3 * 4);
  for (size_t i = 0; i < b.size(); i += 3) {
    uint32_t v = uint32_t(b[i]) << 16;
    if (i + 1 < b.size()) v |= uint32_t(b[i + 1]) << 8;
    if (i + 2 < b.size()) v |= b[i + 2];
    o += kB64[v >> 18 & 63];
    o += kB64[v >> 12 & 63];
    o += i + 1 < b.size() ? kB64[v >> 6 & 63] : '=';
    o += i + 2 < b.size() ? kB64[v & 63] : '=';
  }
  return o;
}

std::optional<Bytes> b64_decode(const std::string &s) {
  if (s.size() % 4) return std::nullopt;
  Bytes o;
  o.reserve(s.size() / 4 * 3);
  uint32_t v = 0;
  for (size_t i = 0; i < s.size(); i++) {
    char c = s[i];
    int d;
    if (c >= 'A' && c <= 'Z') d = c - 'A';
    else if (c >= 'a' && c <= 'z') d = c - 'a' + 26;
    else if (c >= '0' && c <= '9') d = c - '0' + 52;
    else if (c == '+') d = 62;
    else if (c == '/') d = 63;
    else if (c == '=' && i + 2 >= s.size()) d = 0;
    else return std::nullopt;
    v = v << 6 | uint32_t(d);
    if (i % 4 == 3) {
      o.push_back(uint8_t(v >> 16));
      if (s[i - 1] != '=') o.push_back(uint8_t(v >> 8));
      if (s[i] != '=') o.push_back(uint8_t(v));
    }
  }
  return o;
}

Bytes str_bytes(const std::string &s) { return Bytes(s.begin(), s.end()); }
std::string bytes_str(const Bytes &b) { return std::string(b.begin(), b.end()); }

void random_bytes(uint8_t *p, size_t n) {
#if defined(__APPLE__)
  arc4random_buf(p, n);
#else
  // Unbuffered, so key bytes are not left behind in a stdio buffer.
  int fd = ::open("/dev/urandom", O_RDONLY | O_CLOEXEC);
  if (fd < 0) throw std::runtime_error("no secure random source");
  size_t got = 0;
  while (got < n) {
    ssize_t r = ::read(fd, p + got, n - got);
    if (r < 0 && errno == EINTR) continue;
    if (r <= 0) break;
    got += size_t(r);
  }
  ::close(fd);
  if (got != n) throw std::runtime_error("short read from secure random source");
#endif
}

std::string random_id() {
  uint8_t b[16];
  random_bytes(b, sizeof b);
  return to_hex(b, sizeof b);
}

void wipe(void *p, size_t n) { crypto_wipe(p, n); }

Identity Identity::from_seed(const Key32 &seed) {
  Identity me;
  me.seed = seed;
  uint8_t tmp[32];
  std::memcpy(tmp, seed.data(), 32);  // key_pair wipes its seed argument
  crypto_ed25519_key_pair(me.sign_sk.data(), me.sign_pk.data(), tmp);
  static const char ctx[] = "sync-box-key-v1";
  crypto_blake2b_keyed(me.box_sk.data(), 32, seed.data(), 32,
                       reinterpret_cast<const uint8_t *>(ctx), sizeof ctx - 1);
  crypto_x25519_public_key(me.box_pk.data(), me.box_sk.data());
  return me;
}

Bytes Identity::sign(const Bytes &msg) const {
  Bytes sig(64);
  crypto_ed25519_sign(sig.data(), sign_sk.data(), msg.data(), msg.size());
  return sig;
}

static Bytes box_binding(const Key32 &box_pk) {
  Bytes m = str_bytes("sync-box-binding-v1");
  m.insert(m.end(), box_pk.begin(), box_pk.end());
  return m;
}

Bytes Identity::box_signature() const { return sign(box_binding(box_pk)); }

bool verify_signature(const Key32 &sign_pk, const Bytes &msg, const Bytes &sig) {
  if (sig.size() != 64) return false;
  return crypto_ed25519_check(sig.data(), sign_pk.data(), msg.data(), msg.size()) == 0;
}

bool verify_box_key(const std::string &user_id, const Key32 &box_pk, const Bytes &box_sig) {
  auto pk = key_from_hex(user_id);
  return pk && verify_signature(*pk, box_binding(box_pk), box_sig);
}

// key = BLAKE2b(ee_dh || ss_dh || eph_pk || from_id || to_id)
static Key32 envelope_key(const uint8_t dh1[32], const uint8_t dh2[32], const uint8_t eph_pk[32],
                          const std::string &from_id, const std::string &to_id) {
  crypto_blake2b_ctx c;
  static const char label[] = "sync-e2ee-v1";
  crypto_blake2b_keyed_init(&c, 32, reinterpret_cast<const uint8_t *>(label), sizeof label - 1);
  crypto_blake2b_update(&c, dh1, 32);
  crypto_blake2b_update(&c, dh2, 32);
  crypto_blake2b_update(&c, eph_pk, 32);
  crypto_blake2b_update(&c, reinterpret_cast<const uint8_t *>(from_id.data()), from_id.size());
  crypto_blake2b_update(&c, reinterpret_cast<const uint8_t *>(to_id.data()), to_id.size());
  Key32 k;
  crypto_blake2b_final(&c, k.data());
  return k;
}

static const uint8_t kEnvelopeVersion = 1;
static const size_t kEnvelopeHeader = 1 + 32 + 24 + 16;

Bytes seal(const Identity &me, const std::string &to_id, const Key32 &to_box_pk,
           const Bytes &plaintext) {
  uint8_t eph_sk[32], eph_pk[32], dh1[32], dh2[32];
  random_bytes(eph_sk, 32);
  crypto_x25519_public_key(eph_pk, eph_sk);
  crypto_x25519(dh1, eph_sk, to_box_pk.data());
  crypto_x25519(dh2, me.box_sk.data(), to_box_pk.data());
  Key32 key = envelope_key(dh1, dh2, eph_pk, me.id(), to_id);

  Bytes out(kEnvelopeHeader + plaintext.size());
  out[0] = kEnvelopeVersion;
  std::memcpy(&out[1], eph_pk, 32);
  random_bytes(&out[33], 24);
  crypto_aead_lock(out.data() + kEnvelopeHeader, &out[57], key.data(), &out[33], nullptr, 0,
                   plaintext.data(), plaintext.size());
  crypto_wipe(eph_sk, 32);
  crypto_wipe(dh1, 32);
  crypto_wipe(dh2, 32);
  crypto_wipe(key.data(), 32);
  return out;
}

std::optional<Bytes> open(const Identity &me, const std::string &from_id,
                          const Key32 &from_box_pk, const Bytes &env) {
  if (env.size() < kEnvelopeHeader || env[0] != kEnvelopeVersion) return std::nullopt;
  uint8_t dh1[32], dh2[32];
  crypto_x25519(dh1, me.box_sk.data(), &env[1]);
  crypto_x25519(dh2, me.box_sk.data(), from_box_pk.data());
  Key32 key = envelope_key(dh1, dh2, &env[1], from_id, me.id());
  Bytes pt(env.size() - kEnvelopeHeader);
  int rc = crypto_aead_unlock(pt.data(), &env[57], key.data(), &env[33], nullptr, 0,
                              env.data() + kEnvelopeHeader, pt.size());
  crypto_wipe(dh1, 32);
  crypto_wipe(dh2, 32);
  crypto_wipe(key.data(), 32);
  if (rc != 0) return std::nullopt;
  return pt;
}

Bytes aead_seal(const Key32 &key, const Bytes &pt, const std::string &ad) {
  Bytes out(24 + 16 + pt.size());
  random_bytes(out.data(), 24);
  crypto_aead_lock(out.data() + 40, out.data() + 24, key.data(), out.data(),
                   reinterpret_cast<const uint8_t *>(ad.data()), ad.size(), pt.data(), pt.size());
  return out;
}

std::optional<Bytes> aead_open(const Key32 &key, const Bytes &s, const std::string &ad) {
  if (s.size() < 40) return std::nullopt;
  Bytes pt(s.size() - 40);
  if (crypto_aead_unlock(pt.data(), s.data() + 24, key.data(), s.data(),
                         reinterpret_cast<const uint8_t *>(ad.data()), ad.size(), s.data() + 40,
                         pt.size()) != 0)
    return std::nullopt;
  return pt;
}

std::string group_id_for(const std::string &creator_id, const std::string &salt) {
  std::string joined = "sync-group-v1" + creator_id + salt;
  uint8_t h[16];
  crypto_blake2b(h, sizeof h, reinterpret_cast<const uint8_t *>(joined.data()), joined.size());
  return to_hex(h, sizeof h);
}

std::string safety_number(const std::string &a, const std::string &b) {
  const std::string &lo = a < b ? a : b, &hi = a < b ? b : a;
  std::string joined = lo + hi;
  uint8_t h[30];
  crypto_blake2b(h, sizeof h, reinterpret_cast<const uint8_t *>(joined.data()), joined.size());
  std::string out;
  for (size_t i = 0; i + 2 < sizeof h; i += 3) {
    char buf[8];
    uint32_t v = (uint32_t(h[i]) << 16 | uint32_t(h[i + 1]) << 8 | h[i + 2]) % 100000;
    std::snprintf(buf, sizeof buf, "%05u", v);
    if (!out.empty()) out += ' ';
    out += buf;
  }
  return out;
}

}  // namespace sync_core
