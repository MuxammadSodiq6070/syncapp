// POSIX WebSocket (RFC 6455) client and HTTP/1.1 helpers, over TCP or TLS.
// wss:// verifies the server certificate and hostname against the bundled CA roots.
#pragma once
#include <cstdint>
#include <memory>
#include <optional>
#include <string>
#include <vector>

namespace sync_core {

struct Endpoint {
  std::string host;
  std::string port;
  bool tls = false;
};
std::optional<Endpoint> parse_ws_url(const std::string &url);

#ifdef SYNC_TESTING
// Lets tests trust a throwaway CA. Compiled out of every shipped library.
void set_test_ca_pem(const std::string &pem);
#endif

// One connection, plain or TLS. All socket I/O is non-blocking underneath, so a
// stalled peer can never hold the caller past the deadlines used here.
class Stream {
 public:
  Stream();
  ~Stream();
  bool connect(const Endpoint &ep, std::string *err);
  void close();
  bool is_open() const { return fd_ >= 0; }
  int fd() const { return fd_; }
  bool send_all(const uint8_t *p, size_t n);
  // >0 bytes read, 0 peer closed, -1 error, -2 nothing available right now.
  int read_some(uint8_t *p, size_t n);
  // Like read_some but waits for data, up to timeout_ms. Returns -2 on timeout.
  int read_wait(uint8_t *p, size_t n, int timeout_ms);

 private:
  struct Tls;
  int fd_ = -1;
  std::unique_ptr<Tls> tls_;
};

class WebSocket {
 public:
  ~WebSocket() { close(); }
  bool connect(const Endpoint &ep, const std::string &path, std::string *err);
  void close();
  bool is_open() const { return s_.is_open(); }
  int fd() const { return s_.fd(); }
  bool send_text(const std::string &s);
  // Drains the socket without blocking and appends complete text messages.
  // Returns false once the connection is gone.
  bool read_available(std::vector<std::string> *out);

 private:
  bool send_frame(uint8_t opcode, const uint8_t *data, size_t n);
  bool parse_frames(std::vector<std::string> *out);
  Stream s_;
  std::string in_;
  std::string partial_;
};

struct HttpResult {
  int status = 0;
  std::vector<uint8_t> body;
  std::string error;
};
// max_body bounds the response while it is read, so a hostile server cannot grow
// client memory; the whole exchange also has an overall deadline.
HttpResult http_request(const Endpoint &ep, const std::string &method, const std::string &path,
                        const std::string &bearer, const std::vector<uint8_t> &body, size_t max_body);

}  // namespace sync_core
