#include "net.h"

#include <fcntl.h>
#include <netdb.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <sys/socket.h>
#include <unistd.h>

#include <algorithm>
#include <cctype>
#include <cerrno>
#include <chrono>
#include <cstdlib>
#include <cstring>
#include <mutex>

#include "crypto.h"
#include "mbedtls/ctr_drbg.h"
#include "mbedtls/entropy.h"
#include "mbedtls/error.h"
#include "mbedtls/net_sockets.h"
#include "mbedtls/sha1.h"
#include "mbedtls/ssl.h"
#include "mbedtls/x509_crt.h"
#include "psa/crypto.h"

#ifndef MSG_NOSIGNAL
#define MSG_NOSIGNAL 0  // Apple: SO_NOSIGPIPE is set on the socket instead
#endif

namespace sync_core {

extern const char kCaBundlePem[];

static const size_t kMaxFrame = 8 * 1024 * 1024;
static const int kConnectMs = 10000;
static const int kHandshakeMs = 20000;
static const int kIoMs = 30000;
static const int kHttpTotalMs = 300000;

#ifdef SYNC_TESTING
static std::string g_test_ca;
void set_test_ca_pem(const std::string &pem) { g_test_ca = pem; }
#endif

static int64_t mono_ms() {
  return std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now().time_since_epoch())
      .count();
}

std::optional<Endpoint> parse_ws_url(const std::string &url) {
  Endpoint ep;
  std::string rest;
  if (url.rfind("wss://", 0) == 0) {
    ep.tls = true;
    rest = url.substr(6);
  } else if (url.rfind("ws://", 0) == 0) {
    rest = url.substr(5);
  } else {
    return std::nullopt;
  }
  auto slash = rest.find('/');
  if (slash != std::string::npos) rest = rest.substr(0, slash);
  auto colon = rest.rfind(':');
  if (colon == std::string::npos) {
    ep.host = rest;
    ep.port = ep.tls ? "443" : "80";
  } else {
    ep.host = rest.substr(0, colon);
    ep.port = rest.substr(colon + 1);
  }
  if (ep.host.empty() || ep.port.empty()) return std::nullopt;
  for (char c : ep.host + ep.port)  // goes into HTTP headers
    if (std::isspace(static_cast<unsigned char>(c)) || std::iscntrl(static_cast<unsigned char>(c))) return std::nullopt;
  return ep;
}

static int tcp_connect(const Endpoint &ep, std::string *err) {
  addrinfo hints{}, *res = nullptr;
  hints.ai_socktype = SOCK_STREAM;
  hints.ai_family = AF_UNSPEC;
  int rc = getaddrinfo(ep.host.c_str(), ep.port.c_str(), &hints, &res);
  if (rc != 0) {
    if (err) *err = gai_strerror(rc);
    return -1;
  }
  int fd = -1;
  for (addrinfo *a = res; a; a = a->ai_next) {
    fd = socket(a->ai_family, a->ai_socktype, a->ai_protocol);
    if (fd < 0) continue;
    fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK);
    fcntl(fd, F_SETFD, FD_CLOEXEC);
    int c = ::connect(fd, a->ai_addr, a->ai_addrlen);
    if (c != 0 && errno == EINPROGRESS) {
      pollfd p{fd, POLLOUT, 0};
      if (poll(&p, 1, kConnectMs) == 1) {
        int e = 0;
        socklen_t l = sizeof e;
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &e, &l);
        c = e == 0 ? 0 : -1;
        if (e) errno = e;
      } else {
        errno = ETIMEDOUT;
      }
    }
    if (c == 0) {
      int one = 1;
      setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
#ifdef SO_NOSIGPIPE
      setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one);
#endif
      break;
    }
    if (err) *err = std::strerror(errno);
    ::close(fd);
    fd = -1;
  }
  freeaddrinfo(res);
  return fd;
}

static bool wait_fd(int fd, short ev, int timeout_ms) {
  pollfd p{fd, ev, 0};
  for (;;) {
    int r = poll(&p, 1, timeout_ms);
    if (r < 0 && errno == EINTR) continue;
    return r > 0;
  }
}

static int bio_send(void *ctx, const unsigned char *buf, size_t len) {
  ssize_t w = ::send(*static_cast<int *>(ctx), buf, len, MSG_NOSIGNAL | MSG_DONTWAIT);
  if (w >= 0) return int(w);
  if (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) return MBEDTLS_ERR_SSL_WANT_WRITE;
  return MBEDTLS_ERR_NET_CONN_RESET;
}

static int bio_recv(void *ctx, unsigned char *buf, size_t len) {
  ssize_t r = ::recv(*static_cast<int *>(ctx), buf, len, MSG_DONTWAIT);
  if (r >= 0) return int(r);
  if (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) return MBEDTLS_ERR_SSL_WANT_READ;
  return MBEDTLS_ERR_NET_CONN_RESET;
}

struct Stream::Tls {
  mbedtls_ssl_context ssl;
  mbedtls_ssl_config conf;
  mbedtls_x509_crt ca;
  mbedtls_entropy_context entropy;
  mbedtls_ctr_drbg_context drbg;
  Tls() {
    mbedtls_ssl_init(&ssl);
    mbedtls_ssl_config_init(&conf);
    mbedtls_x509_crt_init(&ca);
    mbedtls_entropy_init(&entropy);
    mbedtls_ctr_drbg_init(&drbg);
  }
  ~Tls() {
    mbedtls_ssl_free(&ssl);
    mbedtls_ssl_config_free(&conf);
    mbedtls_x509_crt_free(&ca);
    mbedtls_ctr_drbg_free(&drbg);
    mbedtls_entropy_free(&entropy);
  }
};

Stream::Stream() = default;
Stream::~Stream() { close(); }

void Stream::close() {
  if (tls_ && fd_ >= 0) mbedtls_ssl_close_notify(&tls_->ssl);
  tls_.reset();
  if (fd_ >= 0) {
    ::close(fd_);
    fd_ = -1;
  }
}

static std::string tls_error(int rc) {
  char buf[128];
  mbedtls_strerror(rc, buf, sizeof buf);
  return std::string("TLS: ") + buf;
}

bool Stream::connect(const Endpoint &ep, std::string *err) {
  close();
  fd_ = tcp_connect(ep, err);
  if (fd_ < 0) return false;
  if (!ep.tls) return true;

  static std::once_flag psa_once;
  std::call_once(psa_once, [] { psa_crypto_init(); });

  tls_ = std::make_unique<Tls>();
  Tls &t = *tls_;
  auto fail = [&](int rc) {
    if (err) *err = tls_error(rc);
    tls_.reset();  // no close_notify on a session that never existed
    ::close(fd_);
    fd_ = -1;
    return false;
  };
  int rc = mbedtls_ctr_drbg_seed(&t.drbg, mbedtls_entropy_func, &t.entropy, nullptr, 0);
  if (rc) return fail(rc);
  const char *pem = kCaBundlePem;
#ifdef SYNC_TESTING
  if (!g_test_ca.empty()) pem = g_test_ca.c_str();
#endif
  rc = mbedtls_x509_crt_parse(&t.ca, reinterpret_cast<const unsigned char *>(pem), std::strlen(pem) + 1);
  if (rc < 0) return fail(rc);
  rc = mbedtls_ssl_config_defaults(&t.conf, MBEDTLS_SSL_IS_CLIENT, MBEDTLS_SSL_TRANSPORT_STREAM, MBEDTLS_SSL_PRESET_DEFAULT);
  if (rc) return fail(rc);
  mbedtls_ssl_conf_min_tls_version(&t.conf, MBEDTLS_SSL_VERSION_TLS1_2);
  mbedtls_ssl_conf_authmode(&t.conf, MBEDTLS_SSL_VERIFY_REQUIRED);
  mbedtls_ssl_conf_ca_chain(&t.conf, &t.ca, nullptr);
  mbedtls_ssl_conf_rng(&t.conf, mbedtls_ctr_drbg_random, &t.drbg);
  rc = mbedtls_ssl_setup(&t.ssl, &t.conf);
  if (rc) return fail(rc);
  rc = mbedtls_ssl_set_hostname(&t.ssl, ep.host.c_str());
  if (rc) return fail(rc);
  mbedtls_ssl_set_bio(&t.ssl, &fd_, bio_send, bio_recv, nullptr);

  int64_t deadline = mono_ms() + kHandshakeMs;
  for (;;) {
    rc = mbedtls_ssl_handshake(&t.ssl);
    if (rc == 0) return true;
    int left = int(deadline - mono_ms());
    if (left <= 0) return fail(MBEDTLS_ERR_SSL_TIMEOUT);
    if (rc == MBEDTLS_ERR_SSL_WANT_READ) wait_fd(fd_, POLLIN, left);
    else if (rc == MBEDTLS_ERR_SSL_WANT_WRITE) wait_fd(fd_, POLLOUT, left);
    else return fail(rc);
  }
}

bool Stream::send_all(const uint8_t *p, size_t n) {
  if (fd_ < 0) return false;
  int64_t deadline = mono_ms() + kIoMs;
  while (n) {
    int w;
    bool want_read = false;
    if (tls_) {
      w = mbedtls_ssl_write(&tls_->ssl, p, n);
      if (w == MBEDTLS_ERR_SSL_WANT_READ) want_read = true;
      else if (w == MBEDTLS_ERR_SSL_RECEIVED_NEW_SESSION_TICKET) continue;
      else if (w < 0 && w != MBEDTLS_ERR_SSL_WANT_WRITE) return false;
    } else {
      ssize_t r = ::send(fd_, p, n, MSG_NOSIGNAL | MSG_DONTWAIT);
      if (r < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) return false;
      w = r < 0 ? MBEDTLS_ERR_SSL_WANT_WRITE : int(r);
    }
    if (w > 0) {
      p += w;
      n -= size_t(w);
      continue;
    }
    int left = int(deadline - mono_ms());
    if (left <= 0 || !wait_fd(fd_, want_read ? POLLIN : POLLOUT, left)) return false;
  }
  return true;
}

int Stream::read_some(uint8_t *p, size_t n) {
  if (fd_ < 0) return -1;
  if (!tls_) {
    for (;;) {
      ssize_t r = ::recv(fd_, p, n, MSG_DONTWAIT);
      if (r >= 0) return int(r);
      if (errno == EINTR) continue;
      return errno == EAGAIN || errno == EWOULDBLOCK ? -2 : -1;
    }
  }
  for (;;) {
    int r = mbedtls_ssl_read(&tls_->ssl, p, n);
    if (r >= 0) return r;
    if (r == MBEDTLS_ERR_SSL_RECEIVED_NEW_SESSION_TICKET) continue;  // TLS 1.3 housekeeping
    if (r == MBEDTLS_ERR_SSL_PEER_CLOSE_NOTIFY) return 0;
    if (r == MBEDTLS_ERR_SSL_WANT_READ || r == MBEDTLS_ERR_SSL_WANT_WRITE) return -2;
    return -1;
  }
}

int Stream::read_wait(uint8_t *p, size_t n, int timeout_ms) {
  int64_t deadline = mono_ms() + timeout_ms;
  for (;;) {
    int r = read_some(p, n);
    if (r != -2) return r;
    int left = int(deadline - mono_ms());
    if (left <= 0 || !wait_fd(fd_, POLLIN, left)) return -2;
  }
}

static std::string lower_copy(std::string s) {
  for (auto &c : s) c = char(std::tolower(static_cast<unsigned char>(c)));
  return s;
}

// Value of a header by exact name, from a raw header block. Empty if absent.
static std::string header_value(const std::string &head, const std::string &name) {
  size_t pos = head.find("\r\n");
  while (pos != std::string::npos) {
    size_t start = pos + 2, end = head.find("\r\n", start);
    std::string line = head.substr(start, end == std::string::npos ? std::string::npos : end - start);
    auto colon = line.find(':');
    if (colon != std::string::npos && lower_copy(line.substr(0, colon)) == name) {
      size_t v = line.find_first_not_of(" \t", colon + 1);
      return v == std::string::npos ? "" : line.substr(v);
    }
    pos = end;
  }
  return "";
}

bool WebSocket::connect(const Endpoint &ep, const std::string &path, std::string *err) {
  close();
  if (!s_.connect(ep, err)) return false;
  uint8_t nonce[16];
  random_bytes(nonce, sizeof nonce);
  std::string key = b64_encode(Bytes(nonce, nonce + 16));
  std::string req = "GET " + path + " HTTP/1.1\r\nHost: " + ep.host + ":" + ep.port +
                    "\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: " + key +
                    "\r\nSec-WebSocket-Version: 13\r\n\r\n";
  if (!s_.send_all(reinterpret_cast<const uint8_t *>(req.data()), req.size())) {
    if (err) *err = "handshake send failed";
    close();
    return false;
  }
  // One byte at a time so no frame bytes are consumed with the headers.
  std::string head;
  uint8_t c;
  int64_t deadline = mono_ms() + kHandshakeMs;
  while (head.size() < 8192 && head.find("\r\n\r\n") == std::string::npos) {
    int r = s_.read_wait(&c, 1, std::max<int>(1, int(deadline - mono_ms())));
    if (r <= 0) {
      if (err) *err = "handshake read failed";
      close();
      return false;
    }
    head += char(c);
  }
  if (head.rfind("HTTP/1.1 101", 0) != 0) {
    if (err) *err = "gateway refused upgrade: " + head.substr(0, head.find('\r'));
    close();
    return false;
  }
  std::string expect = key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
  uint8_t digest[20];
  mbedtls_sha1(reinterpret_cast<const unsigned char *>(expect.data()), expect.size(), digest);
  if (header_value(head, "sec-websocket-accept") != b64_encode(Bytes(digest, digest + 20))) {
    if (err) *err = "gateway sent a bad WebSocket accept";
    close();
    return false;
  }
  return true;
}

void WebSocket::close() {
  s_.close();
  in_.clear();
  partial_.clear();
}

bool WebSocket::send_frame(uint8_t opcode, const uint8_t *data, size_t n) {
  if (!s_.is_open()) return false;
  std::vector<uint8_t> f;
  f.reserve(n + 14);
  f.push_back(0x80 | opcode);
  if (n < 126) {
    f.push_back(uint8_t(0x80 | n));
  } else if (n < 65536) {
    f.push_back(0x80 | 126);
    f.push_back(uint8_t(n >> 8));
    f.push_back(uint8_t(n));
  } else {
    f.push_back(0x80 | 127);
    for (int i = 7; i >= 0; i--) f.push_back(uint8_t(uint64_t(n) >> (i * 8)));
  }
  uint8_t mask[4];
  random_bytes(mask, 4);
  f.insert(f.end(), mask, mask + 4);
  size_t start = f.size();
  f.resize(start + n);
  for (size_t i = 0; i < n; i++) f[start + i] = data[i] ^ mask[i & 3];
  if (!s_.send_all(f.data(), f.size())) {
    close();
    return false;
  }
  return true;
}

bool WebSocket::send_text(const std::string &s) {
  return send_frame(1, reinterpret_cast<const uint8_t *>(s.data()), s.size());
}

bool WebSocket::read_available(std::vector<std::string> *out) {
  if (!s_.is_open()) return false;
  uint8_t buf[65536];
  for (;;) {
    int r = s_.read_some(buf, sizeof buf);
    if (r > 0) {
      in_.append(reinterpret_cast<char *>(buf), size_t(r));
      // Parsing per read keeps in_ near one frame, whatever the peer sends.
      if (!parse_frames(out)) return false;
      continue;
    }
    if (r == -2) return true;
    close();
    return false;
  }
}

bool WebSocket::parse_frames(std::vector<std::string> *out) {
  for (;;) {
    if (!s_.is_open()) return false;
    if (in_.size() < 2) return true;
    auto b = reinterpret_cast<const uint8_t *>(in_.data());
    bool fin = b[0] & 0x80;
    uint8_t op = b[0] & 0x0f;
    bool masked = b[1] & 0x80;
    uint64_t len = b[1] & 0x7f;
    size_t pos = 2;
    if (len == 126) {
      if (in_.size() < 4) return true;
      len = uint64_t(b[2]) << 8 | b[3];
      pos = 4;
    } else if (len == 127) {
      if (in_.size() < 10) return true;
      len = 0;
      for (int i = 0; i < 8; i++) len = len << 8 | b[2 + i];
      pos = 10;
    }
    // A gateway must not mask frames (RFC 6455 5.1).
    if (masked || len > kMaxFrame) {
      close();
      return false;
    }
    if (in_.size() < pos + len) return true;
    std::string payload = in_.substr(pos, size_t(len));
    in_.erase(0, pos + size_t(len));
    switch (op) {
      case 0:
      case 1:
        partial_ += payload;
        if (partial_.size() > kMaxFrame) {
          close();
          return false;
        }
        if (fin) {
          out->push_back(std::move(partial_));
          partial_.clear();
        }
        break;
      case 8:
        close();
        return false;
      case 9:
        if (!send_frame(10, reinterpret_cast<const uint8_t *>(payload.data()), payload.size())) return false;
        break;
      default:
        break;
    }
  }
}

HttpResult http_request(const Endpoint &ep, const std::string &method, const std::string &path,
                        const std::string &bearer, const std::vector<uint8_t> &body, size_t max_body) {
  HttpResult res;
  Stream s;
  if (!s.connect(ep, &res.error)) return res;
  std::string head = method + " " + path + " HTTP/1.1\r\nHost: " + ep.host + ":" + ep.port +
                     "\r\nConnection: close\r\nContent-Length: " + std::to_string(body.size()) + "\r\n";
  if (!bearer.empty()) head += "Authorization: Bearer " + bearer + "\r\n";
  head += "\r\n";
  if (!s.send_all(reinterpret_cast<const uint8_t *>(head.data()), head.size()) ||
      (!body.empty() && !s.send_all(body.data(), body.size()))) {
    res.error = "upload interrupted";
    return res;
  }

  int64_t deadline = mono_ms() + kHttpTotalMs;
  const size_t kMaxHeader = 64 * 1024;
  std::vector<uint8_t> in;
  uint8_t buf[65536];
  static const char sep[] = "\r\n\r\n";
  size_t body_at = 0;
  for (;;) {
    int left = int(deadline - mono_ms());
    int r = left > 0 ? s.read_wait(buf, sizeof buf, std::min(left, kIoMs)) : -2;
    if (r == -2) {
      res.error = "download timed out";
      return res;
    }
    if (r < 0) {
      res.error = "download interrupted";
      return res;
    }
    if (r == 0) break;
    in.insert(in.end(), buf, buf + r);
    if (!body_at) {
      auto it = std::search(in.begin(), in.end(), sep, sep + 4);
      if (it != in.end()) body_at = size_t(it - in.begin()) + 4;
      else if (in.size() > kMaxHeader) {
        res.error = "malformed HTTP response";
        return res;
      }
    }
    if (body_at && in.size() - body_at > max_body) {
      res.error = "response larger than allowed";
      return res;
    }
  }
  if (!body_at) {
    res.error = "malformed HTTP response";
    return res;
  }
  std::string h(in.begin(), in.begin() + long(body_at) - 2);  // keeps the last CRLF for header_value
  if (h.size() < 12 || h.rfind("HTTP/1.", 0) != 0) {
    res.error = "malformed HTTP response";
    return res;
  }
  res.status = std::atoi(h.c_str() + 9);
  res.body.assign(in.begin() + long(body_at), in.end());
  // Reject a truncated body when the server declared its length.
  std::string cl = header_value(h, "content-length");
  if (!cl.empty() && size_t(std::atoll(cl.c_str())) != res.body.size()) {
    res.status = 0;
    res.error = "truncated response";
  }
  return res;
}

}  // namespace sync_core
