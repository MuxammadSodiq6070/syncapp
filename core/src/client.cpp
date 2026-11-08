// The sync_core client: one worker thread owns the socket, keys and database.
// Everything crossing a thread boundary is queued, so handlers below need no locks.
#include <fcntl.h>
#include <poll.h>
#include <sys/stat.h>
#include <unistd.h>

#include <algorithm>
#include <atomic>
#include <cctype>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <filesystem>
#include <fstream>
#include <functional>
#include <iterator>
#include <map>
#include <memory>
#include <mutex>
#include <optional>
#include <random>
#include <set>
#include <thread>

#include "../include/sync_core.h"
#include "crypto.h"
#include "db.h"
#include "json.hpp"
#include "net.h"

namespace sync_core {

using J = nlohmann::json;

static const int64_t kStoryTtlMs = 24 * 3600 * 1000;
static const size_t kMaxMedia = 50 * 1024 * 1024;
static const size_t kMaxSealedMedia = kMaxMedia + 64;
static const size_t kMaxText = 60000;
static const int kMaxJsonDepth = 32;
// Older envelopes are refused, which is what lets the replay cache be pruned.
// It must outlast the gateway's queue retention (30 days).
static const int64_t kEnvelopeMaxAgeMs = 35ll * 24 * 3600 * 1000;
static const size_t kMaxStoriesPerSender = 20;
static const size_t kMaxStoryDownloads = 4;
static const uintmax_t kMaxStoryCacheBytes = 512ull * 1024 * 1024;

static int64_t now_ms() {
  return std::chrono::duration_cast<std::chrono::milliseconds>(
             std::chrono::system_clock::now().time_since_epoch())
      .count();
}

// Sync's own chats. Not identities: no key can produce these names, and the peer
// path files messages under "u:<sender>" or a "g:" group, so neither can be forged.
static const char *kSavedChatId = "saved";
static const char *kServiceChatId = "service";

static bool valid_hex_id(const std::string &s) {
  if (s.empty() || s.size() > 64) return false;
  for (char c : s)
    if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))) return false;
  return true;
}
static bool valid_user_id(const std::string &s) { return s.size() == 64 && valid_hex_id(s); }

// nlohmann's parser is iterative but copying is recursive, so nesting has to be
// refused before a value exists. Counts brackets outside strings, in linear time.
static bool json_depth_ok(const std::string &s) {
  int depth = 0;
  bool in_string = false, escaped = false;
  for (char c : s) {
    if (in_string) {
      if (escaped) escaped = false;
      else if (c == '\\') escaped = true;
      else if (c == '"') in_string = false;
    } else if (c == '"') {
      in_string = true;
    } else if (c == '[' || c == '{') {
      if (++depth > kMaxJsonDepth) return false;
    } else if (c == ']' || c == '}') {
      depth--;
    }
  }
  return true;
}

static J parse_untrusted(const std::string &s) {
  if (!json_depth_ok(s)) throw std::runtime_error("JSON nested too deeply");
  return J::parse(s);
}

static std::string str_of(const J &o, const char *key) {
  auto it = o.find(key);
  return it != o.end() && it->is_string() ? it->get<std::string>() : std::string();
}
static int64_t int_of(const J &o, const char *key) {
  auto it = o.find(key);
  return it != o.end() && it->is_number_integer() ? it->get<int64_t>() : 0;
}

// Builds message content from only the fields each kind uses, with the right types.
// Peers are untrusted, and everything downstream can then rely on the shape. Returns
// null if required fields are missing. local_path exists only on this device, so it
// survives only when reading our own stored rows.
static J clean_content(const std::string &kind, const J &c, bool keep_local) {
  if (!c.is_object()) return nullptr;
  J out = J::object();
  if (kind == "text") {
    auto it = c.find("text");
    if (it == c.end() || !it->is_string()) return nullptr;
    out["text"] = *it;
  } else if (kind == "poll") {
    auto q = c.find("question"), o = c.find("options");
    if (q == c.end() || !q->is_string() || o == c.end() || !o->is_array()) return nullptr;
    if (o->size() < 2 || o->size() > 10) return nullptr;
    if (!std::all_of(o->begin(), o->end(), [](const J &x) { return x.is_string(); })) return nullptr;
    out["question"] = *q;
    out["options"] = *o;
  } else if (kind == "service") {
    // A message from Sync itself. "service" names which notice this is, and the app
    // writes the sentence in the reader's own language, so neither a hostile gateway
    // nor a tampered row can put chosen words into a chat that shows a verified mark.
    auto it = c.find("service");
    if (it == c.end() || !it->is_string()) return nullptr;
    out["service"] = *it;
    auto at = c.find("at");
    if (at != c.end() && at->is_number_integer()) out["at"] = *at;
    auto place = c.find("place");
    if (place != c.end() && place->is_string() && place->get<std::string>().size() <= 64) {
      out["place"] = *place;
    }
  } else if (kind == "image" || kind == "file") {
    std::string media = str_of(c, "media_id"), key = str_of(c, "key");
    if (!valid_hex_id(media) || key.size() != 64 || !valid_hex_id(key)) return nullptr;
    out["media_id"] = media;
    out["key"] = key;
    out["name"] = str_of(c, "name");
    out["mime"] = str_of(c, "mime");
    out["caption"] = str_of(c, "caption");
    out["size"] = std::max<int64_t>(0, int_of(c, "size"));
    out["w"] = std::clamp<int64_t>(int_of(c, "w"), 0, 100000);
    out["h"] = std::clamp<int64_t>(int_of(c, "h"), 0, 100000);
    if (keep_local && c.contains("local_path")) out["local_path"] = str_of(c, "local_path");
  } else {
    return nullptr;
  }
  return out;
}

static J clean_story(const J &c, bool keep_local) {
  if (!c.is_object()) return nullptr;
  std::string kind = str_of(c, "kind");
  J out = {{"kind", kind}};
  if (kind == "text") {
    out["text"] = str_of(c, "text");
    out["color"] = std::clamp<int64_t>(int_of(c, "color"), 0, 1000);
  } else if (kind == "image") {
    std::string media = str_of(c, "media_id"), key = str_of(c, "key");
    if (!valid_hex_id(media) || key.size() != 64 || !valid_hex_id(key)) return nullptr;
    out["media_id"] = media;
    out["key"] = key;
    out["caption"] = str_of(c, "caption");
    if (keep_local && c.contains("local_path")) out["local_path"] = str_of(c, "local_path");
  } else {
    return nullptr;
  }
  return out;
}

class Client {
 public:
  Client(std::string dir, Key32 local_key, std::string url)
      : dir_(std::move(dir)), local_key_(local_key), db_(dir_ + "/sync.db") {
    chmod(dir_.c_str(), 0700);
    mkdir((dir_ + "/media").c_str(), 0700);
    load_identity();
    // Names the install, not the person: it is what lets the gateway notice a
    // sign-in from somewhere else and say so in the service chat.
    if (get_meta("device_id").empty()) set_meta("device_id", random_id());
    // Sync's own two chats. Reserved names, so no identity and no group can reach
    // them: a peer message is filed under "u:<sender>" or a "g:" group, never here.
    ensure_chat(kSavedChatId, "saved", "active");
    ensure_chat(kServiceChatId, "service", "active");
    auto ep = parse_ws_url(url);
    if (!ep) throw std::runtime_error("gateway_url must be ws://host:port");
    ep_ = *ep;
    if (pipe(wake_) != 0) throw std::runtime_error("pipe failed");
    // sync_client_send promises not to block, even if the worker is stalled.
    fcntl(wake_[1], F_SETFL, fcntl(wake_[1], F_GETFL, 0) | O_NONBLOCK);
    worker_ = std::thread([this] { run(); });
  }

  ~Client() {
    running_ = false;
    wake();
    worker_.join();
    {
      std::unique_lock<std::mutex> l(helper_m_);
      helper_cv_.wait(l, [this] { return helpers_ == 0; });
    }
    close(wake_[0]);
    close(wake_[1]);
  }

  void send(std::string json) {
    post([this, json = std::move(json)] { handle_request(json); });
  }

  char *receive(double timeout) {
    std::unique_lock<std::mutex> l(out_m_);
    out_cv_.wait_for(l, std::chrono::duration<double>(timeout), [this] { return !out_.empty(); });
    if (out_.empty()) return nullptr;
    std::string s = std::move(out_.front());
    out_.pop_front();
    return strdup(s.c_str());
  }

 private:
  // ---- plumbing -------------------------------------------------------------
  void post(std::function<void()> fn) {
    {
      std::lock_guard<std::mutex> l(in_m_);
      in_.push_back(std::move(fn));
    }
    wake();
  }
  void wake() {
    char c = 1;
    (void)!write(wake_[1], &c, 1);
  }
  void emit(J j) {
    std::string s = j.dump(-1, ' ', false, J::error_handler_t::replace);
    {
      std::lock_guard<std::mutex> l(out_m_);
      out_.push_back(std::move(s));
    }
    out_cv_.notify_one();
  }
  // Background network job. The destructor waits for these, so `this` stays valid.
  void spawn(std::function<void()> fn) {
    {
      std::lock_guard<std::mutex> l(helper_m_);
      helpers_++;
    }
    std::thread([this, fn = std::move(fn)] {
      // An exception leaving a thread ends the whole app.
      try {
        fn();
      } catch (const std::exception &e) {
        post([this, m = std::string(e.what())] { emit({{"@type", "log"}, {"message", "helper error: " + m}}); });
      }
      std::lock_guard<std::mutex> l(helper_m_);
      helpers_--;
      helper_cv_.notify_all();
    }).detach();
  }

  void run() {
    set_state("connecting");
    while (running_) {
      int64_t now = now_ms();
      if (ws_ && !ws_->is_open()) on_disconnect("connection lost");
      if (!ws_ && !connecting_ && !auth_blocked_ && now >= next_connect_) start_connect();
      if (ws_ && now - last_rx_ > 75000) on_disconnect("gateway timed out");

      pollfd fds[2] = {{wake_[0], POLLIN, 0}, {ws_ ? ws_->fd() : -1, POLLIN, 0}};
      poll(fds, 2, 1000);
      if (fds[0].revents & POLLIN) {
        char b[256];
        (void)!read(wake_[0], b, sizeof b);
      }
      std::deque<std::function<void()>> jobs;
      {
        std::lock_guard<std::mutex> l(in_m_);
        jobs.swap(in_);
      }
      for (auto &j : jobs) {
        try {
          j();
        } catch (const std::exception &e) {
          emit({{"@type", "log"}, {"message", std::string("job error: ") + e.what()}});
        }
      }

      if (ws_ && ws_->is_open() && (fds[1].revents & (POLLIN | POLLHUP | POLLERR))) {
        last_rx_ = now_ms();  // includes keepalive pings, which produce no messages
        std::vector<std::string> msgs;
        bool alive = ws_->read_available(&msgs);
        for (auto &m : msgs) handle_frame(m);
        if (!alive && ws_) on_disconnect("connection closed");
      }
    }
    ws_.reset();
  }

  void start_connect() {
    connecting_ = true;
    Endpoint ep = ep_;
    spawn([this, ep] {
      auto sock = std::make_shared<WebSocket>();
      std::string err;
      bool ok = sock->connect(ep, "/ws", &err);
      post([this, sock, ok, err] {
        connecting_ = false;
        if (ok) {
          ws_ = sock;
          last_rx_ = now_ms();
          retry_ = 0;
        } else {
          schedule_reconnect(err);
        }
      });
    });
  }

  void schedule_reconnect(const std::string &why) {
    static thread_local std::mt19937 rng{std::random_device{}()};
    int64_t base = std::min<int64_t>(30000, 1000ll << std::min(retry_, 5));
    retry_++;
    next_connect_ = now_ms() + base / 2 + int64_t(rng() % uint64_t(base / 2 + 1));
    set_state("offline", why);
  }

  void on_disconnect(const std::string &why) {
    ws_.reset();
    authed_ = false;
    inflight_.clear();
    key_requests_.clear();
    auto pending = std::move(pending_);
    pending_.clear();
    for (auto &p : pending) p.second(J{{"ok", false}, {"error", "offline"}});
    schedule_reconnect(why);
  }

  void set_state(const std::string &s, const std::string &detail = "") {
    state_ = s;
    emit({{"@type", "updateConnection"}, {"state", s}, {"detail", detail}});
  }

  // ---- gateway requests -----------------------------------------------------
  using Cb = std::function<void(const J &)>;

  void gw(J req, Cb cb = nullptr) {
    if (!authed_ || !ws_) {
      if (cb) cb(J{{"ok", false}, {"error", "offline"}});
      return;
    }
    if (cb) {
      std::string rid = std::to_string(++rid_);
      req["rid"] = rid;
      pending_[rid] = std::move(cb);
    }
    ws_->send_text(req.dump());
  }

  void handle_frame(const std::string &raw) {
    try {
      J m = parse_untrusted(raw);
      std::string t = m.at("t");
      if (t == "challenge") {
        auto nonce = from_hex(m.at("nonce").get<std::string>());
        if (!nonce) return;
        Bytes payload = str_bytes("sync-auth-v1");
        payload.insert(payload.end(), nonce->begin(), nonce->end());
        ws_->send_text(J{{"t", "auth"},
                         {"id", me_.id()},
                         {"box_pk", to_hex(me_.box_pk)},
                         {"box_sig", to_hex(me_.box_signature())},
                         {"sig", to_hex(me_.sign(payload))},
                         {"device", get_meta("device_id")},
                         {"ticket", auth_ticket_},
                         {"fb_token", auth_token_},
                         {"phone", auth_phone_},
                         {"code", auth_code_}}
                           .dump());
      } else if (t == "auth_error") {
        // Registration needs something only the app can supply, so retrying this
        // connection is pointless. Wait for setAuthToken instead.
        auth_token_.clear();
        auth_code_.clear();
        auth_ticket_.clear();
        auth_blocked_ = true;
        set_state("unverified", m.value("reason", "verification_required"));
      } else if (t == "service") {
        on_service(m);
      } else if (t == "ready") {
        authed_ = true;
        J profile = m.value("profile", J::object());
        set_meta("username", profile.value("username", ""));
        set_meta("display_name", profile.value("display_name", ""));
        // Accepted; keeping the proof serves no purpose.
        auth_token_.clear();
        auth_phone_.clear();
        auth_code_.clear();
        auth_ticket_.clear();
        set_state("ready");
        emit({{"@type", "updateMe"}, {"me", me_json()}});
        auto now = now_ms();
        db_.prepare("DELETE FROM seen_envelopes WHERE ts<?").bind(1, now - kEnvelopeMaxAgeMs).run();
        flush_outbox();
        watch_all();
      } else if (t == "res") {
        auto it = pending_.find(m.at("rid").get<std::string>());
        if (it != pending_.end()) {
          Cb cb = std::move(it->second);
          pending_.erase(it);
          cb(m);
        }
      } else if (t == "msg") {
        int64_t seq = m.at("seq");
        // A malformed envelope is dropped and still acked, or it would loop forever.
        try {
          handle_envelope(m, false);
        } catch (const std::exception &e) {
          emit({{"@type", "log"}, {"message", std::string("dropped envelope: ") + e.what()}});
        }
        if (ws_) ws_->send_text(J{{"t", "ack"}, {"seq", seq}}.dump());
      } else if (t == "transient") {
        handle_envelope(m, true);
      } else if (t == "presence") {
        emit({{"@type", "updateUserStatus"},
              {"user_id", m.at("id")},
              {"online", m.at("online")},
              {"last_seen", m.value("last_seen", 0)}});
      }
    } catch (const std::exception &e) {
      emit({{"@type", "log"}, {"message", std::string("bad frame: ") + e.what()}});
    }
  }

  // ---- identity and metadata ------------------------------------------------
  void set_meta(const std::string &k, const std::string &v) {
    db_.prepare("INSERT OR REPLACE INTO meta VALUES(?,?)").bind(1, k).bind(2, str_bytes(v)).run();
  }
  std::string get_meta(const std::string &k) {
    auto s = db_.prepare("SELECT v FROM meta WHERE k=?");
    s.bind(1, k);
    return s.step() ? bytes_str(s.blob(0)) : "";
  }

  void load_identity() {
    auto s = db_.prepare("SELECT v FROM meta WHERE k='seed'");
    if (s.step()) {
      auto pt = aead_open(local_key_, s.blob(0), "seed");
      if (!pt || pt->size() != 32) throw std::runtime_error("wrong local key for this database");
      Key32 seed;
      std::memcpy(seed.data(), pt->data(), 32);
      wipe(pt->data(), pt->size());
      me_ = Identity::from_seed(seed);
    } else {
      Key32 seed;
      random_bytes(seed.data(), 32);
      store_seed(seed);
      me_ = Identity::from_seed(seed);
    }
  }
  void store_seed(const Key32 &seed) {
    Bytes plain(seed.begin(), seed.end());
    db_.prepare("INSERT OR REPLACE INTO meta VALUES('seed',?)")
        .bind(1, aead_seal(local_key_, plain, "seed"))
        .run();
    wipe(plain.data(), plain.size());
  }

  J me_json() {
    return {{"id", me_.id()},
            {"username", get_meta("username")},
            {"display_name", get_meta("display_name")}};
  }

  void remember_user(const J &u) {
    std::string id = u.at("id");
    if (!valid_user_id(id)) return;
    auto box = key_from_hex(u.value("box_pk", ""));
    auto sig = from_hex(u.value("box_sig", ""));
    // The gateway is untrusted: only accept keys the identity itself signed.
    if (!box || !sig || !verify_box_key(id, *box, *sig)) return;
    db_.prepare(
           "INSERT INTO users(id,box_pk,username,display_name) VALUES(?1,?2,?3,?4) "
           "ON CONFLICT(id) DO UPDATE SET box_pk=?2,username=?3,display_name=?4")
        .bind(1, id)
        .bind(2, to_hex(*box))
        .bind(3, u.value("username", ""))
        .bind(4, u.value("display_name", ""))
        .run();
  }

  J user_json(const std::string &id) {
    if (id == me_.id()) return me_json();
    auto s = db_.prepare("SELECT username,display_name,blocked FROM users WHERE id=?");
    s.bind(1, id);
    if (!s.step())
      return {{"id", id}, {"username", ""}, {"display_name", id.substr(0, 8)}, {"blocked", false}};
    std::string name = s.text(1);
    if (name.empty()) name = s.text(0);
    if (name.empty()) name = id.substr(0, 8);
    return {{"id", id}, {"username", s.text(0)}, {"display_name", name}, {"blocked", s.i64(2) != 0}};
  }

  std::optional<Key32> box_key(const std::string &id) {
    auto s = db_.prepare("SELECT box_pk FROM users WHERE id=?");
    s.bind(1, id);
    if (!s.step() || s.is_null(0)) return std::nullopt;
    return key_from_hex(s.text(0));
  }

  // ---- outbound messages ----------------------------------------------------
  std::vector<std::string> recipients(const std::string &chat_id) {
    std::vector<std::string> out;
    if (chat_id.rfind("u:", 0) == 0) {
      out.push_back(chat_id.substr(2));
      return out;
    }
    auto s = db_.prepare("SELECT user_id FROM members WHERE chat_id=?");
    s.bind(1, chat_id);
    while (s.step())
      if (s.text(0) != me_.id()) out.push_back(s.text(0));
    return out;
  }

  void enqueue(const std::string &to, const J &payload, const std::string &mid = "") {
    // eid is fixed here, so a resend after a lost reply is still the same envelope.
    J p = payload;
    p["eid"] = random_id();
    p["sent"] = now_ms();
    auto st = db_.prepare("INSERT INTO outbox(recipient,mid,payload) VALUES(?,?,?)");
    st.bind(1, to);
    if (mid.empty()) st.bind_null(2);
    else st.bind(2, mid);
    st.bind(3, aead_seal(local_key_, str_bytes(p.dump()), "outbox")).run();
  }

  void enqueue_chat(const std::string &chat_id, const J &payload, const std::string &mid = "") {
    for (auto &to : recipients(chat_id)) enqueue(to, payload, mid);
  }

  void flush_outbox() {
    if (!authed_) return;
    struct Row {
      int64_t seq;
      std::string to, mid;
      Bytes payload;
    };
    std::vector<Row> rows;
    {
      auto s = db_.prepare("SELECT seq,recipient,mid,payload FROM outbox ORDER BY seq LIMIT 500");
      while (s.step()) rows.push_back({s.i64(0), s.text(1), s.text(2), s.blob(3)});
    }
    for (auto &r : rows) {
      if (inflight_.count(r.seq)) continue;
      auto key = box_key(r.to);
      if (!key) {
        fetch_key_then_flush(r.to);
        continue;
      }
      auto pt = aead_open(local_key_, r.payload, "outbox");
      if (!pt) {
        db_.prepare("DELETE FROM outbox WHERE seq=?").bind(1, r.seq).run();
        continue;
      }
      inflight_.insert(r.seq);
      int64_t seq = r.seq;
      std::string mid = r.mid;
      gw({{"t", "send"}, {"to", r.to}, {"blob", b64_encode(seal(me_, r.to, *key, *pt))}},
         [this, seq, mid](const J &res) {
           inflight_.erase(seq);
           if (!res.value("ok", false)) {
             // Only a permanent refusal drops the row; anything else retries on reconnect.
             if (res.value("error", "") != "unknown_user") return;
           }
           db_.prepare("DELETE FROM outbox WHERE seq=?").bind(1, seq).run();
           if (!mid.empty()) mark_sent(mid);
           if (inflight_.empty()) flush_outbox();  // pick up rows past the batch limit
         });
    }
  }

  void fetch_key_then_flush(const std::string &id) {
    if (!key_requests_.insert(id).second) return;
    gw({{"t", "user"}, {"id", id}}, [this, id](const J &res) {
      key_requests_.erase(id);
      if (res.value("ok", false) && res.contains("user")) {
        remember_user(res["user"]);
        if (box_key(id)) flush_outbox();
      }
    });
  }

  void mark_sent(const std::string &mid) {
    auto left = db_.prepare("SELECT 1 FROM outbox WHERE mid=? LIMIT 1");
    left.bind(1, mid);
    if (left.step()) return;
    db_.prepare("UPDATE messages SET status='sent' WHERE id=? AND status='sending'").bind(1, mid).run();
    if (db_.changes()) emit_message(mid);
  }

  void send_transient(const std::string &to, const J &payload) {
    auto key = box_key(to);
    if (!key || !authed_) return;
    gw({{"t", "send"},
        {"to", to},
        {"transient", true},
        {"blob", b64_encode(seal(me_, to, *key, str_bytes(payload.dump())))}});
  }

  // ---- local model ----------------------------------------------------------
  void ensure_chat(const std::string &id, const std::string &type, const std::string &state) {
    db_.prepare("INSERT OR IGNORE INTO chats(id,type,state,updated_at) VALUES(?,?,?,?)")
        .bind(1, id)
        .bind(2, type)
        .bind(3, state)
        .bind(4, now_ms())
        .run();
    if (db_.changes() && type == "direct") watch_all();
  }

  J body_of(const std::string &mid, const Bytes &sealed) {
    auto pt = aead_open(local_key_, sealed, mid);
    if (!pt) return J::object();
    if (!json_depth_ok(bytes_str(*pt))) return J::object();
    J j = J::parse(bytes_str(*pt), nullptr, false);
    return j.is_object() ? j : J::object();
  }

  J message_json(const std::string &id) {
    auto s = db_.prepare(
        "SELECT chat_id,sender,kind,body,status,ts,reply_to,edited,deleted FROM messages WHERE id=?");
    s.bind(1, id);
    if (!s.step()) return nullptr;
    bool deleted = s.i64(8) != 0;
    std::string chat = s.text(0);
    J m = {{"id", id},
           {"chat_id", chat},
           {"sender", s.text(1)},
           {"outgoing", s.text(1) == me_.id()},
           {"kind", s.text(2)},
           {"content", J::object()},
           {"status", s.text(4)},
           {"ts", s.i64(5)},
           {"edited", s.i64(7) != 0},
           {"deleted", deleted}};
    if (!deleted) {
      // Rows stored before content was validated are cleaned here too.
      J clean = clean_content(s.text(2), body_of(id, s.blob(3)), true);
      if (!clean.is_null()) m["content"] = clean;
    }
    if (!s.is_null(6)) {
      std::string rid = s.text(6);
      m["reply_to"] = rid;
      // Same-chat only: a peer must not be able to quote messages from other chats.
      auto r = db_.prepare("SELECT sender,kind,body,deleted FROM messages WHERE id=? AND chat_id=?");
      r.bind(1, rid).bind(2, chat);
      if (r.step() && r.i64(3) == 0) {
        J body = body_of(rid, r.blob(2));
        m["reply_preview"] = {{"sender", user_json(r.text(0))["display_name"]},
                              {"kind", r.text(1)},
                              {"text", str_of(body, "text")}};
      }
    }
    J reactions = J::array();
    auto rs = db_.prepare("SELECT user_id,emoji FROM reactions WHERE message_id=?");
    rs.bind(1, id);
    while (rs.step()) reactions.push_back({{"user", rs.text(0)}, {"emoji", rs.text(1)}});
    m["reactions"] = reactions;
    if (m["kind"] == "poll") {
      J votes = J::array();
      auto vs = db_.prepare("SELECT user_id,option FROM votes WHERE message_id=?");
      vs.bind(1, id);
      while (vs.step()) votes.push_back({{"user", vs.text(0)}, {"option", vs.i64(1)}});
      m["votes"] = votes;
    }
    return m;
  }

  void emit_message(const std::string &id) {
    J m = message_json(id);
    if (!m.is_null()) emit({{"@type", "updateMessage"}, {"message", m}});
  }

  J chat_json(const std::string &id) {
    auto s = db_.prepare(
        "SELECT type,title,admin,state,archived,muted,unread,last_message,updated_at FROM chats WHERE id=?");
    s.bind(1, id);
    if (!s.step()) return nullptr;
    J c = {{"id", id},
           {"type", s.text(0)},
           {"title", s.text(1)},
           {"admin", s.text(2)},
           {"state", s.text(3)},
           {"archived", s.i64(4) != 0},
           {"muted", s.i64(5) != 0},
           {"unread", s.i64(6)},
           {"updated_at", s.i64(8)}};
    J members = J::array();
    if (s.text(0) == "direct") {
      J peer = user_json(id.substr(2));
      c["title"] = peer["display_name"];
      c["peer"] = peer;
      members.push_back(peer);
    } else {
      auto ms = db_.prepare("SELECT user_id FROM members WHERE chat_id=?");
      ms.bind(1, id);
      while (ms.step()) members.push_back(user_json(ms.text(0)));
    }
    c["members"] = members;
    if (!s.is_null(7)) c["last_message"] = message_json(s.text(7));
    return c;
  }

  void emit_chat(const std::string &id) {
    J c = chat_json(id);
    if (!c.is_null()) emit({{"@type", "updateChat"}, {"chat", c}});
  }

  void touch_chat(const std::string &chat, const std::string &mid, int64_t ts, bool unread) {
    db_.prepare(
           "UPDATE chats SET last_message=?2, updated_at=MAX(updated_at,?3), unread=unread+?4, "
           "archived=CASE WHEN ?4=1 AND muted=0 THEN 0 ELSE archived END WHERE id=?1")
        .bind(1, chat)
        .bind(2, mid)
        .bind(3, ts)
        .bind(4, int64_t(unread ? 1 : 0))
        .run();
  }

  std::string store_outgoing(const std::string &chat, const std::string &kind, const J &content,
                             const std::string &reply_to, const J &wire_content) {
    std::string mid = random_id();
    int64_t ts = now_ms();
    auto st = db_.prepare(
        "INSERT INTO messages(id,chat_id,sender,kind,body,status,ts,reply_to) VALUES(?,?,?,?,?,?,?,?)");
    st.bind(1, mid).bind(2, chat).bind(3, me_.id()).bind(4, kind);
    st.bind(5, aead_seal(local_key_, str_bytes(content.dump()), mid)).bind(6, std::string("sending")).bind(7, ts);
    if (reply_to.empty()) st.bind_null(8);
    else st.bind(8, reply_to);
    st.run();
    touch_chat(chat, mid, ts, false);
    J payload = {{"k", "msg"}, {"mid", mid}, {"kind", kind}, {"content", wire_content}, {"ts", ts}};
    if (chat.rfind("g:", 0) == 0) payload["conv"] = chat;
    if (!reply_to.empty()) payload["reply_to"] = reply_to;
    enqueue_chat(chat, payload, mid);
    emit_message(mid);
    emit_chat(chat);
    mark_sent(mid);  // a group with no other members has nothing to wait for
    flush_outbox();
    return mid;
  }

  bool is_member(const std::string &chat, const std::string &user) {
    if (chat.rfind("u:", 0) == 0) return chat.substr(2) == user || user == me_.id();
    auto s = db_.prepare("SELECT 1 FROM members WHERE chat_id=? AND user_id=?");
    s.bind(1, chat).bind(2, user);
    return s.step();
  }

  // Chat id of a message `user` is allowed to act on, or "" if none.
  std::string chat_of(const std::string &mid, const std::string &user) {
    auto s = db_.prepare("SELECT chat_id FROM messages WHERE id=?");
    s.bind(1, mid);
    if (!s.step()) return "";
    std::string chat = s.text(0);
    return is_member(chat, user) ? chat : "";
  }

  // ---- inbound E2EE payloads ------------------------------------------------
  void handle_envelope(const J &m, bool transient) {
    std::string from = m.at("from");
    if (!valid_user_id(from) || from == me_.id()) return;
    if (m.contains("sender") && m["sender"].is_object() && str_of(m["sender"], "id") == from) remember_user(m["sender"]);
    auto key = box_key(from);
    auto blob = b64_decode(m.at("blob").get<std::string>());
    if (!key || !blob) return;
    auto pt = open(me_, from, *key, *blob);
    if (!pt) {
      emit({{"@type", "log"}, {"message", "dropped envelope that failed authentication"}});
      return;
    }
    auto blocked = db_.prepare("SELECT blocked FROM users WHERE id=?");
    blocked.bind(1, from);
    if (blocked.step() && blocked.i64(0)) return;
    J p = parse_untrusted(bytes_str(*pt));
    std::string k = p.at("k");
    if (k == "typing") {
      on_typing(from, p);
      return;
    }
    // Everything else changes state, so it arrives once, from the durable queue.
    // The seal authenticates eid and sent; this covers replay by an untrusted relay,
    // including replay after a chat was deleted, because the cache is separate.
    if (transient) return;
    std::string eid = str_of(p, "eid");
    int64_t sent = int_of(p, "sent"), now = now_ms();
    if (!valid_hex_id(eid) || sent <= 0 || now - sent > kEnvelopeMaxAgeMs) return;
    db_.prepare("INSERT OR IGNORE INTO seen_envelopes(sender,eid,ts) VALUES(?,?,?)")
        .bind(1, from)
        .bind(2, eid)
        .bind(3, now)
        .run();
    if (!db_.changes()) return;
    if (k == "msg") on_msg(from, p);
    else if (k == "edit") on_edit(from, p);
    else if (k == "del") on_delete(from, p);
    else if (k == "react") on_react(from, p);
    else if (k == "vote") on_vote(from, p);
    else if (k == "rcpt") on_receipt(from, p);
    else if (k == "group") on_group(from, p);
    else if (k == "leave") on_leave(from, p);
    else if (k == "story") on_story(from, p);
  }

  // A message from Sync itself, over the authenticated connection. The gateway is
  // its author, so it is not end-to-end encrypted and the app labels it as such; it
  // is stored under the reserved service chat, which no peer can write to. The body
  // carries a key, not a sentence, so the app shows it in the reader's language and
  // a hostile gateway cannot put words of its own on a verified-looking chat.
  void on_service(const J &m) {
    std::string mid = str_of(m, "id");
    if (!valid_hex_id(mid)) return;
    J body = m.value("body", J::object());
    if (!body.is_object()) return;
    J content = {{"service", str_of(body, "text")}};
    if (content["service"].get<std::string>().empty()) return;
    if (body.contains("at") && body["at"].is_number_integer()) content["at"] = body["at"];
    std::string place = str_of(body, "place");
    if (!place.empty() && place.size() <= 64) content["place"] = place;
    int64_t ts = int_of(m, "ts");
    if (ts <= 0 || ts > now_ms()) ts = now_ms();
    auto st = db_.prepare(
        "INSERT OR IGNORE INTO messages(id,chat_id,sender,kind,body,status,ts) VALUES(?,?,?,?,?,?,?)");
    st.bind(1, mid).bind(2, std::string(kServiceChatId)).bind(3, std::string(kServiceChatId));
    st.bind(4, std::string("service"));
    st.bind(5, aead_seal(local_key_, str_bytes(content.dump()), mid));
    st.bind(6, std::string("received")).bind(7, ts);
    st.run();
    if (!db_.changes()) return;  // already delivered once
    touch_chat(kServiceChatId, mid, ts, true);
    emit({{"@type", "updateNewMessage"}, {"message", message_json(mid)}});
    emit_chat(kServiceChatId);
  }

  void on_msg(const std::string &from, const J &p) {
    std::string mid = p.at("mid");
    std::string kind = p.at("kind");
    if (!valid_hex_id(mid)) return;
    J content = clean_content(kind, p.at("content"), false);
    if (content.is_null()) return;
    std::string chat = str_of(p, "conv");
    if (chat.empty()) {
      chat = "u:" + from;
      ensure_chat(chat, "direct", "request");
    } else {
      // A group we are not in stays closed, even if the sender is listed in it.
      if (chat.rfind("g:", 0) != 0 || !is_member(chat, from) || !is_member(chat, me_.id())) return;
    }
    int64_t ts = int_of(p, "ts");
    if (ts <= 0 || ts > now_ms()) ts = now_ms();
    auto st = db_.prepare(
        "INSERT OR IGNORE INTO messages(id,chat_id,sender,kind,body,status,ts,reply_to) VALUES(?,?,?,?,?,?,?,?)");
    st.bind(1, mid).bind(2, chat).bind(3, from).bind(4, kind);
    st.bind(5, aead_seal(local_key_, str_bytes(content.dump()), mid)).bind(6, std::string("received")).bind(7, ts);
    std::string reply = str_of(p, "reply_to");
    if (!valid_hex_id(reply)) st.bind_null(8);
    else st.bind(8, reply);
    st.run();
    if (!db_.changes()) return;  // replay or duplicate delivery
    touch_chat(chat, mid, ts, true);
    emit({{"@type", "updateNewMessage"}, {"message", message_json(mid)}});
    emit_chat(chat);
    auto state = db_.prepare("SELECT state FROM chats WHERE id=?");
    state.bind(1, chat);
    if (state.step() && state.text(0) == "active") {
      enqueue(from, {{"k", "rcpt"}, {"st", "delivered"}, {"mids", J::array({mid})}});
      flush_outbox();
    }
  }

  void on_edit(const std::string &from, const J &p) {
    std::string mid = p.at("mid");
    if (!p.at("text").is_string() || p["text"].get_ref<const std::string &>().size() > kMaxText) return;
    if (chat_of(mid, from).empty()) return;  // removal ends the right to rewrite history
    auto s = db_.prepare("SELECT body,edit_ts FROM messages WHERE id=? AND sender=? AND deleted=0 AND kind='text'");
    s.bind(1, mid).bind(2, from);
    if (!s.step()) return;
    int64_t sent = int_of(p, "sent");
    if (sent <= s.i64(1)) return;  // an older edit delivered late must not win
    J body = body_of(mid, s.blob(0));
    body["text"] = p.at("text");
    db_.prepare("UPDATE messages SET body=?,edited=1,edit_ts=? WHERE id=?")
        .bind(1, aead_seal(local_key_, str_bytes(body.dump()), mid))
        .bind(2, sent)
        .bind(3, mid)
        .run();
    emit_message(mid);
  }

  void on_delete(const std::string &from, const J &p) {
    std::string mid = p.at("mid");
    if (chat_of(mid, from).empty()) return;
    db_.prepare("UPDATE messages SET deleted=1,body=? WHERE id=? AND sender=?")
        .bind(1, aead_seal(local_key_, str_bytes("{}"), mid))
        .bind(2, mid)
        .bind(3, from)
        .run();
    if (db_.changes()) {
      remove_cached_media(mid);
      emit_message(mid);
    }
  }

  void on_react(const std::string &from, const J &p) {
    std::string mid = p.at("mid");
    if (chat_of(mid, from).empty()) return;
    apply_reaction(mid, from, p.at("emoji"));
    emit_message(mid);
  }
  void apply_reaction(const std::string &mid, const std::string &user, const std::string &emoji) {
    if (emoji.empty()) {
      db_.prepare("DELETE FROM reactions WHERE message_id=? AND user_id=?").bind(1, mid).bind(2, user).run();
    } else if (emoji.size() <= 32) {
      db_.prepare("INSERT OR REPLACE INTO reactions VALUES(?,?,?)").bind(1, mid).bind(2, user).bind(3, emoji).run();
    }
  }

  void on_vote(const std::string &from, const J &p) {
    std::string mid = p.at("mid");
    if (chat_of(mid, from).empty()) return;
    int64_t option = p.at("option").get<int64_t>();
    auto q = db_.prepare("SELECT body FROM messages WHERE id=? AND kind='poll' AND deleted=0");
    q.bind(1, mid);
    if (!q.step()) return;
    J body = clean_content("poll", body_of(mid, q.blob(0)), false);
    if (body.is_null() || option < 0 || option >= int64_t(body["options"].size())) return;
    db_.prepare("INSERT OR REPLACE INTO votes VALUES(?,?,?)").bind(1, mid).bind(2, from).bind(3, option).run();
    emit_message(mid);
  }

  void on_receipt(const std::string &from, const J &p) {
    std::string st = p.at("st");
    if (st != "delivered" && st != "read") return;
    for (const auto &midj : p.at("mids")) {
      std::string mid = midj;
      if (chat_of(mid, from).empty()) continue;
      const char *sql = st == "read"
                            ? "UPDATE messages SET status='read' WHERE id=? AND sender=? AND status!='read'"
                            : "UPDATE messages SET status='delivered' WHERE id=? AND sender=? AND status IN('sending','sent')";
      db_.prepare(sql).bind(1, mid).bind(2, me_.id()).run();
      if (db_.changes()) emit_message(mid);
    }
  }

  void set_members(const std::string &chat, const std::set<std::string> &members) {
    db_.prepare("DELETE FROM members WHERE chat_id=?").bind(1, chat).run();
    for (auto &u : members)
      db_.prepare("INSERT INTO members VALUES(?,?)").bind(1, chat).bind(2, u).run();
  }

  void on_group(const std::string &from, const J &p) {
    std::string chat = p.at("conv");
    if (chat.rfind("g:", 0) != 0 || !valid_hex_id(chat.substr(2))) return;
    int64_t ver = p.at("ver");
    auto s = db_.prepare("SELECT admin,version FROM chats WHERE id=?");
    s.bind(1, chat);
    bool exists = s.step();
    std::set<std::string> members;
    for (const auto &u : p.at("members")) {
      std::string id = u;
      if (valid_user_id(id)) members.insert(id);
    }
    if (!members.count(from) || members.size() > 1024) return;
    bool me_in = members.count(me_.id()) != 0;
    std::string creator = str_of(p, "creator"), salt = str_of(p, "salt");
    if (exists) {
      // Only the current admin may change a group, and versions only move forward,
      // by a bounded step so one update cannot lock out every later one.
      if (s.text(0) != from || s.i64(1) >= ver || ver > s.i64(1) + 1000) return;
    } else {
      // A new group must prove its id belongs to the creator, must come from that
      // creator, and must include us. Anything else is a claim on someone else's id,
      // or a way around the request inbox.
      if (creator != from || !valid_hex_id(salt) || group_id_for(creator, salt) != chat.substr(2)) return;
      if (!me_in || ver <= 0 || ver > 1000) return;
    }
    Tx tx(db_);
    ensure_chat(chat, "group", "request");
    db_.prepare(
           "UPDATE chats SET title=?1,admin=?2,version=?3,state=CASE WHEN ?4=0 THEN 'left' "
           "WHEN state='left' THEN 'request' ELSE state END WHERE id=?5")
        .bind(1, p.at("title").get<std::string>().substr(0, 256))
        .bind(2, from)
        .bind(3, ver)
        .bind(4, int64_t(me_in))
        .bind(5, chat)
        .run();
    if (!exists)
      db_.prepare("UPDATE chats SET creator=?,salt=? WHERE id=?").bind(1, creator).bind(2, salt).bind(3, chat).run();
    set_members(chat, members);
    tx.commit();
    for (auto &u : members)
      if (u != me_.id() && !box_key(u)) fetch_key_then_flush(u);
    emit_chat(chat);
  }

  void on_leave(const std::string &from, const J &p) {
    std::string chat = p.at("conv");
    if (chat.rfind("g:", 0) != 0 || !is_member(chat, from)) return;
    // A leave from before the sender was re-added no longer applies.
    auto v = db_.prepare("SELECT version FROM chats WHERE id=?");
    v.bind(1, chat);
    if (!v.step() || int_of(p, "ver") < v.i64(0)) return;
    apply_leave(chat, from);
    emit_chat(chat);
  }

  // Every member computes the same successor if the admin leaves.
  void apply_leave(const std::string &chat, const std::string &user) {
    db_.prepare("DELETE FROM members WHERE chat_id=? AND user_id=?").bind(1, chat).bind(2, user).run();
    auto a = db_.prepare("SELECT admin FROM chats WHERE id=?");
    a.bind(1, chat);
    if (a.step() && a.text(0) == user) {
      auto next = db_.prepare("SELECT MIN(user_id) FROM members WHERE chat_id=?");
      next.bind(1, chat);
      if (next.step() && !next.is_null(0))
        db_.prepare("UPDATE chats SET admin=? WHERE id=?").bind(1, next.text(0)).bind(2, chat).run();
    }
  }

  void on_typing(const std::string &from, const J &p) {
    std::string chat = p.value("conv", "u:" + from);
    if (is_member(chat, from)) emit({{"@type", "updateTyping"}, {"chat_id", chat}, {"user_id", from}});
  }

  void on_story(const std::string &from, const J &p) {
    std::string id = p.at("id");
    if (!valid_hex_id(id)) return;
    // Stories are only taken from people already accepted as contacts.
    auto c = db_.prepare("SELECT state FROM chats WHERE id=?");
    c.bind(1, "u:" + from);
    if (!c.step() || c.text(0) != "active") return;
    J content = clean_story(p.at("content"), false);
    if (content.is_null()) return;
    auto n = db_.prepare("SELECT COUNT(*) FROM stories WHERE sender=?");
    n.bind(1, from);
    if (n.step() && size_t(n.i64(0)) >= kMaxStoriesPerSender) return;
    int64_t ts = int_of(p, "ts");
    if (ts <= 0 || ts > now_ms()) ts = now_ms();
    db_.prepare("INSERT OR IGNORE INTO stories(id,sender,body,ts) VALUES(?,?,?,?)")
        .bind(1, id)
        .bind(2, from)
        .bind(3, aead_seal(local_key_, str_bytes(content.dump()), id))
        .bind(4, ts)
        .run();
    if (db_.changes()) emit({{"@type", "updateStories"}});
  }

  void watch_all() {
    if (!authed_) return;
    J ids = J::array();
    // Only accepted people. The gateway shows presence only between two people who
    // both ask, so asking here is what grants it.
    auto s = db_.prepare("SELECT id FROM chats WHERE type='direct' AND state='active'");
    while (s.step()) ids.push_back(s.text(0).substr(2));
    if (!ids.empty()) gw({{"t", "watch"}, {"ids", ids}});
  }

  // ---- media ----------------------------------------------------------------
  using UploadCb = std::function<void(const std::string &err, const std::string &media_id,
                                      const std::string &key_hex, int64_t size)>;

  void upload_file(const std::string &path, UploadCb done) {
    gw({{"t", "media_token"}}, [this, path, done](const J &res) {
      if (!res.value("ok", false)) return done("offline", "", "", 0);
      std::string token = res.value("token", "");
      Endpoint ep = ep_;
      spawn([this, path, token, ep, done] {
        std::string err, id, key_hex;
        int64_t size = 0;
        std::ifstream f(path, std::ios::binary);
        Bytes data((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
        if (data.empty()) err = "file is empty or unreadable";
        else if (data.size() > kMaxMedia) err = "file is larger than 50 MB";
        else {
          size = int64_t(data.size());
          Key32 key;
          random_bytes(key.data(), 32);
          key_hex = to_hex(key);
          HttpResult r = http_request(ep, "POST", "/media", token, aead_seal(key, data, "media"), 4096);
          if (r.status == 200) {
            std::string text = bytes_str(r.body);
            J j = json_depth_ok(text) ? J::parse(text, nullptr, false) : J();
            id = j.is_object() ? str_of(j, "id") : "";
            if (!valid_hex_id(id)) id.clear();
          }
          if (r.status == 413) err = "This file is too large, or you've reached your upload limit.";
          else if (id.empty()) err = r.error.empty() ? "upload failed (" + std::to_string(r.status) + ")" : r.error;
        }
        post([done, err, id, key_hex, size] { done(err, id, key_hex, size); });
      });
    });
  }

  void download_to(const std::string &media_id, const std::string &key_hex, const std::string &name,
                   std::function<void(const std::string &err, const std::string &path)> done) {
    if (!valid_hex_id(media_id)) return done("bad media id", "");
    auto key = key_from_hex(key_hex);
    if (!key) return done("bad media key", "");
    Endpoint ep = ep_;
    std::string out = dir_ + "/media/" + name;
    spawn([this, media_id, key = *key, out, ep, done] {
      std::string err;
      HttpResult r = http_request(ep, "GET", "/media/" + media_id, "", {}, kMaxSealedMedia);
      if (r.status != 200) {
        err = r.error.empty() ? "download failed (" + std::to_string(r.status) + ")" : r.error;
      } else {
        auto pt = aead_open(key, r.body, "media");
        if (!pt) {
          err = "media failed authentication";
        } else {
          // Private mode from creation, not only through the parent folder.
          int fd = ::open(out.c_str(), O_CREAT | O_WRONLY | O_TRUNC | O_CLOEXEC, 0600);
          size_t done = 0;
          while (fd >= 0 && done < pt->size()) {
            ssize_t w = ::write(fd, pt->data() + done, pt->size() - done);
            if (w <= 0) break;
            done += size_t(w);
          }
          if (fd >= 0) ::close(fd);
          if (done != pt->size()) err = "cannot write media cache";
        }
      }
      post([done, err, out] { done(err, out); });
    });
  }

  // Names are ids we validated when storing them, so this stays inside dir/media.
  // A sender's original picked file lives elsewhere and is never touched.
  void remove_cached_media(const std::string &name) {
    std::string bare = name.rfind("story_", 0) == 0 ? name.substr(6) : name;
    if (valid_hex_id(bare)) std::remove((dir_ + "/media/" + name).c_str());
  }

  // ---- API requests ---------------------------------------------------------
  void reply(const J &req, J res) {
    if (req.contains("@extra")) res["@extra"] = req["@extra"];
    emit(std::move(res));
  }
  void ok(const J &req, J res = J::object()) {
    res["@type"] = "ok";
    reply(req, std::move(res));
  }
  void fail(const J &req, const std::string &msg) { reply(req, {{"@type", "error"}, {"message", msg}}); }

  void handle_request(const std::string &raw) {
    J req = J::parse(raw, nullptr, false);
    if (!req.is_object()) return;
    try {
      dispatch(req, req.value("@type", ""));
    } catch (const std::exception &e) {
      fail(req, e.what());
    }
  }

  void dispatch(const J &r, const std::string &t) {
    if (t == "getMe") {
      ok(r, {{"me", me_json()}, {"state", state_}});
    } else if (t == "setProfile") {
      std::string username = r.at("username"), name = r.at("display_name");
      gw({{"t", "profile"}, {"username", username}, {"display_name", name}},
         [this, r, username, name](const J &res) {
           if (!res.value("ok", false)) return fail(r, res.value("error", "failed"));
           set_meta("username", username);
           set_meta("display_name", name);
           emit({{"@type", "updateMe"}, {"me", me_json()}});
           ok(r, {{"me", me_json()}});
         });
    } else if (t == "exportRecoveryKey") {
      ok(r, {{"key", to_hex(me_.seed)}});
    } else if (t == "importRecoveryKey") {
      auto seed = key_from_hex(r.at("key").get<std::string>());
      if (!seed) return fail(r, "Recovery key must be 64 hex characters");
      auto c = db_.prepare("SELECT 1 FROM chats LIMIT 1");
      if (c.step()) return fail(r, "This device already has chats");
      store_seed(*seed);
      me_ = Identity::from_seed(*seed);
      if (ws_) on_disconnect("identity changed");
      next_connect_ = 0;
      ok(r, {{"me", me_json()}});
    } else if (t == "startTelegramVerify") {
      // Opens a bot conversation and returns the link to send the person to. The
      // bot is what proves the number, so nothing here is a secret the app holds.
      Endpoint ep = ep_;
      spawn([this, r, ep] {
        HttpResult res = http_request(ep, "POST", "/verify/start", "", str_bytes("{}"), 8192);
        post([this, r, res] {
          if (res.status != 200) return fail(r, res.error.empty() ? "offline" : res.error);
          std::string text = bytes_str(res.body);
          J j = json_depth_ok(text) ? J::parse(text, nullptr, false) : J();
          if (!j.is_object()) return fail(r, "server_error");
          if (!j.value("ok", false)) return fail(r, str_of(j, "error"));
          ok(r, {{"nonce", str_of(j, "nonce")}, {"url", str_of(j, "url")}});
        });
      });
    } else if (t == "pollTelegramVerify") {
      // Asks whether the bot has proved a number yet. "waiting" is the normal
      // answer and is not an error the person should ever see.
      std::string nonce = r.at("nonce");
      Endpoint ep = ep_;
      spawn([this, r, ep, nonce] {
        HttpResult res = http_request(ep, "POST", "/verify/poll", "",
                                      str_bytes(J{{"nonce", nonce}}.dump()), 8192);
        post([this, r, res] {
          if (res.status != 200) return fail(r, res.error.empty() ? "offline" : res.error);
          std::string text = bytes_str(res.body);
          J j = json_depth_ok(text) ? J::parse(text, nullptr, false) : J();
          if (!j.is_object()) return fail(r, "server_error");
          ok(r, {{"ready", j.value("ok", false)}, {"ticket", str_of(j, "ticket")}});
        });
      });
    } else if (t == "setAuthTicket") {
      // Proof from the bot that a number belongs to this person. Good for one
      // registration, kept in memory only, and gone as soon as it is accepted.
      auth_ticket_ = r.at("ticket").get<std::string>();
      auth_blocked_ = false;
      next_connect_ = 0;
      retry_ = 0;
      if (ws_) on_disconnect("reconnecting to register");
      ok(r);
    } else if (t == "requestSmsCode") {
      // Asks the gateway to send a sign-up code. The gateway owns every limit;
      // this only carries the request, over the same TLS as everything else.
      std::string phone = r.at("phone");
      Endpoint ep = ep_;
      spawn([this, r, ep, phone] {
        HttpResult res = http_request(ep, "POST", "/verify/request", "",
                                      str_bytes(J{{"phone", phone}}.dump()), 8192);
        post([this, r, res] {
          if (res.status != 200) {
            return fail(r, res.error.empty() ? "offline" : res.error);
          }
          std::string text = bytes_str(res.body);
          J j = json_depth_ok(text) ? J::parse(text, nullptr, false) : J();
          if (!j.is_object()) return fail(r, "server_error");
          if (!j.value("ok", false)) return fail(r, str_of(j, "error"));
          // "via" tells the app whether to point at Telegram or at an SMS inbox.
          ok(r, {{"retry_after", j.value("retry_after", 60)},
                 {"via", str_of(j, "via")}});
        });
      });
    } else if (t == "setAuthCode") {
      // The code the person received. Used for the next connection only, and never
      // written to disk.
      auth_phone_ = r.at("phone").get<std::string>();
      auth_code_ = r.at("code").get<std::string>();
      auth_blocked_ = false;
      next_connect_ = 0;
      retry_ = 0;
      if (ws_) on_disconnect("reconnecting to register");
      ok(r);
    } else if (t == "setAuthToken") {
      // Supplied once, after the app has verified a phone number. It is used for the
      // next connection only and is never written to disk.
      auth_token_ = r.at("token").get<std::string>();
      auth_blocked_ = false;
      next_connect_ = 0;
      retry_ = 0;
      if (ws_) on_disconnect("reconnecting to register");
      ok(r);
    } else if (t == "getSafetyNumber") {
      ok(r, {{"number", safety_number(me_.id(), r.at("user_id"))}});
    } else if (t == "searchUsers") {
      gw({{"t", "search"}, {"q", r.at("query")}}, [this, r](const J &res) {
        if (!res.value("ok", false)) return fail(r, res.value("error", "offline"));
        J users = J::array();
        for (const auto &u : res.value("users", J::array())) {
          if (u.value("id", "") == me_.id()) continue;
          remember_user(u);
          users.push_back({{"id", u.value("id", "")},
                           {"username", u.value("username", "")},
                           {"display_name", u.value("display_name", "")}});
        }
        ok(r, {{"users", users}});
      });
    } else if (t == "openDirectChat") {
      std::string peer = r.at("user_id");
      if (!valid_user_id(peer) || peer == me_.id()) return fail(r, "Invalid user");
      std::string id = "u:" + peer;
      ensure_chat(id, "direct", "active");
      db_.prepare("UPDATE chats SET state='active' WHERE id=?").bind(1, id).run();
      watch_all();
      emit_chat(id);
      ok(r, {{"chat", chat_json(id)}});
    } else if (t == "getChats") {
      std::string filter = r.value("filter", "main");
      // Saved messages is somewhere to put things, so it is offered from the start.
      // The service chat has nothing to say until Sync says it, so it stays out of
      // the list until it holds a message.
      const char *kEmptyOwn = " AND (type!='service' OR last_message IS NOT NULL)";
      std::string sql =
          filter == "archived"
              ? std::string("SELECT id FROM chats WHERE archived=1 AND state!='request'") + kEmptyOwn
          : filter == "requests"
              ? std::string("SELECT id FROM chats WHERE state='request'")
              : std::string("SELECT id FROM chats WHERE archived=0 AND state!='request'") + kEmptyOwn;
      sql += " ORDER BY updated_at DESC";
      J chats = J::array();
      auto s = db_.prepare(sql.c_str());
      while (s.step()) {
        // One unreadable row must not take the whole list with it.
        try {
          chats.push_back(chat_json(s.text(0)));
        } catch (const std::exception &) {
        }
      }
      ok(r, {{"chats", chats}});
    } else if (t == "getChat") {
      J c = chat_json(r.at("chat_id"));
      if (c.is_null()) return fail(r, "Chat not found");
      ok(r, {{"chat", c}});
    } else if (t == "getMessages") {
      int64_t limit = std::clamp<int64_t>(r.value("limit", 50), 1, 200);
      int64_t before = r.value("before", int64_t(INT64_MAX));
      auto s = db_.prepare("SELECT id FROM messages WHERE chat_id=? AND ts<? ORDER BY ts DESC LIMIT ?");
      s.bind(1, r.at("chat_id").get<std::string>()).bind(2, before).bind(3, limit);
      J out = J::array();
      while (s.step()) {
        try {
          out.push_back(message_json(s.text(0)));
        } catch (const std::exception &) {
        }
      }
      ok(r, {{"messages", out}});
    } else if (t == "searchMessages") {
      // Bodies are encrypted at rest, so search decrypts the most recent messages.
      std::string q = lower(r.at("query").get<std::string>());
      auto s = db_.prepare("SELECT id,body FROM messages WHERE kind='text' AND deleted=0 ORDER BY ts DESC LIMIT 5000");
      J out = J::array();
      while (s.step() && out.size() < 50) {
        std::string id = s.text(0);
        J b = body_of(id, s.blob(1));
        if (lower(b.value("text", "")).find(q) != std::string::npos) out.push_back(message_json(id));
      }
      ok(r, {{"messages", out}});
    } else if (t == "sendMessage") {
      std::string chat = require_chat(r);
      std::string text = r.at("text");
      if (text.empty()) return fail(r, "Message is empty");
      if (text.size() > kMaxText) return fail(r, "Message is too long");
      J c = {{"text", text}};
      ok(r, {{"message_id", store_outgoing(chat, "text", c, r.value("reply_to", ""), c)}});
    } else if (t == "sendPoll") {
      std::string chat = require_chat(r);
      J c = {{"question", r.at("question")}, {"options", r.at("options")}};
      if (clean_content("poll", c, false).is_null()) return fail(r, "A poll needs a question and 2 to 10 options");
      ok(r, {{"message_id", store_outgoing(chat, "poll", c, "", c)}});
    } else if (t == "sendMedia") {
      send_media(r);
    } else if (t == "downloadMedia") {
      download_media(r);
    } else if (t == "editMessage") {
      std::string mid = r.at("message_id");
      auto s = db_.prepare("SELECT chat_id,body FROM messages WHERE id=? AND sender=? AND deleted=0 AND kind='text'");
      s.bind(1, mid).bind(2, me_.id());
      if (!s.step()) return fail(r, "Only your own text messages can be edited");
      std::string chat = s.text(0);
      J body = body_of(mid, s.blob(1));
      if (r.at("text").get_ref<const std::string &>().size() > kMaxText) return fail(r, "Message is too long");
      body["text"] = r.at("text");
      db_.prepare("UPDATE messages SET body=?,edited=1 WHERE id=?")
          .bind(1, aead_seal(local_key_, str_bytes(body.dump()), mid))
          .bind(2, mid)
          .run();
      enqueue_chat(chat, {{"k", "edit"}, {"mid", mid}, {"text", r.at("text")}});
      emit_message(mid);
      flush_outbox();
      ok(r);
    } else if (t == "deleteMessage") {
      std::string mid = r.at("message_id");
      auto s = db_.prepare("SELECT chat_id FROM messages WHERE id=? AND sender=?");
      s.bind(1, mid).bind(2, me_.id());
      if (!s.step()) return fail(r, "Only your own messages can be deleted");
      std::string chat = s.text(0);
      db_.prepare("UPDATE messages SET deleted=1,body=? WHERE id=?")
          .bind(1, aead_seal(local_key_, str_bytes("{}"), mid))
          .bind(2, mid)
          .run();
      remove_cached_media(mid);
      enqueue_chat(chat, {{"k", "del"}, {"mid", mid}});
      emit_message(mid);
      emit_chat(chat);
      flush_outbox();
      ok(r);
    } else if (t == "react") {
      std::string mid = r.at("message_id");
      std::string chat = chat_of(mid, me_.id());
      if (chat.empty()) return fail(r, "Message not found");
      std::string emoji = r.value("emoji", "");
      apply_reaction(mid, me_.id(), emoji);
      enqueue_chat(chat, {{"k", "react"}, {"mid", mid}, {"emoji", emoji}});
      emit_message(mid);
      flush_outbox();
      ok(r);
    } else if (t == "votePoll") {
      std::string mid = r.at("message_id");
      std::string chat = chat_of(mid, me_.id());
      if (chat.empty()) return fail(r, "Message not found");
      int64_t option = r.at("option");
      db_.prepare("INSERT OR REPLACE INTO votes VALUES(?,?,?)").bind(1, mid).bind(2, me_.id()).bind(3, option).run();
      enqueue_chat(chat, {{"k", "vote"}, {"mid", mid}, {"option", option}});
      emit_message(mid);
      flush_outbox();
      ok(r);
    } else if (t == "markRead") {
      mark_read(r);
    } else if (t == "setTyping") {
      std::string chat = r.at("chat_id");
      J p = {{"k", "typing"}};
      if (chat.rfind("g:", 0) == 0) p["conv"] = chat;
      for (auto &to : recipients(chat)) send_transient(to, p);
      ok(r);
    } else if (t == "setChatFlag") {
      std::string flag = r.at("flag");
      if (flag != "archived" && flag != "muted") return fail(r, "Unknown flag");
      std::string sql = "UPDATE chats SET " + flag + "=? WHERE id=?";
      db_.prepare(sql.c_str())
          .bind(1, int64_t(r.at("value").get<bool>()))
          .bind(2, r.at("chat_id").get<std::string>())
          .run();
      emit_chat(r.at("chat_id"));
      ok(r);
    } else if (t == "acceptRequest") {
      std::string chat = r.at("chat_id");
      db_.prepare("UPDATE chats SET state='active' WHERE id=? AND state='request'").bind(1, chat).run();
      watch_all();
      emit_chat(chat);
      ok(r);
    } else if (t == "deleteChat") {
      std::string chat = r.at("chat_id");
      {
        auto ids = db_.prepare("SELECT id FROM messages WHERE chat_id=?");
        ids.bind(1, chat);
        while (ids.step()) remove_cached_media(ids.text(0));
      }
      Tx tx(db_);
      db_.prepare("DELETE FROM reactions WHERE message_id IN(SELECT id FROM messages WHERE chat_id=?)").bind(1, chat).run();
      db_.prepare("DELETE FROM votes WHERE message_id IN(SELECT id FROM messages WHERE chat_id=?)").bind(1, chat).run();
      db_.prepare("DELETE FROM messages WHERE chat_id=?").bind(1, chat).run();
      db_.prepare("DELETE FROM members WHERE chat_id=?").bind(1, chat).run();
      db_.prepare("DELETE FROM chats WHERE id=?").bind(1, chat).run();
      tx.commit();
      if (chat.rfind("u:", 0) == 0) gw({{"t", "unwatch"}, {"ids", J::array({chat.substr(2)})}});
      emit({{"@type", "updateChatRemoved"}, {"chat_id", chat}});
      ok(r);
    } else if (t == "setBlocked") {
      std::string user = r.at("user_id");
      bool b = r.at("blocked");
      db_.prepare("INSERT INTO users(id,blocked) VALUES(?1,?2) ON CONFLICT(id) DO UPDATE SET blocked=?2")
          .bind(1, user)
          .bind(2, int64_t(b))
          .run();
      if (b) gw({{"t", "unwatch"}, {"ids", J::array({user})}});
      else watch_all();
      emit_chat("u:" + user);
      ok(r);
    } else if (t == "getBlocked") {
      J out = J::array();
      auto s = db_.prepare("SELECT id FROM users WHERE blocked=1");
      while (s.step()) out.push_back(user_json(s.text(0)));
      ok(r, {{"users", out}});
    } else if (t == "createGroup") {
      create_group(r);
    } else if (t == "updateGroup") {
      update_group(r);
    } else if (t == "leaveGroup") {
      std::string chat = r.at("chat_id");
      if (!is_member(chat, me_.id())) return fail(r, "Not a member");
      int64_t ver = 0;
      {
        auto v = db_.prepare("SELECT version FROM chats WHERE id=?");
        v.bind(1, chat);
        if (v.step()) ver = v.i64(0);
      }
      enqueue_chat(chat, {{"k", "leave"}, {"conv", chat}, {"ver", ver}});
      apply_leave(chat, me_.id());
      db_.prepare("UPDATE chats SET state='left' WHERE id=?").bind(1, chat).run();
      emit_chat(chat);
      flush_outbox();
      ok(r);
    } else if (t == "getListings" || t == "postListing" || t == "deleteListing" || t == "askAi") {
      relay_request(r, t);
    } else if (t == "setKv") {
      std::string key = "kv:" + r.at("key").get<std::string>();
      db_.prepare("INSERT OR REPLACE INTO meta VALUES(?,?)")
          .bind(1, key)
          .bind(2, aead_seal(local_key_, str_bytes(r.at("value").dump()), key))
          .run();
      ok(r);
    } else if (t == "getKv") {
      std::string key = "kv:" + r.at("key").get<std::string>();
      auto s = db_.prepare("SELECT v FROM meta WHERE k=?");
      s.bind(1, key);
      J value = nullptr;
      if (s.step()) {
        auto pt = aead_open(local_key_, s.blob(0), key);
        if (pt) value = J::parse(bytes_str(*pt), nullptr, false);
      }
      ok(r, {{"value", value}});
    } else if (t == "postStory") {
      post_story(r);
    } else if (t == "getStories") {
      get_stories(r);
    } else if (t == "markStorySeen") {
      db_.prepare("UPDATE stories SET seen=1 WHERE id=?").bind(1, r.at("story_id").get<std::string>()).run();
      ok(r);
    } else {
      fail(r, "Unknown request: " + t);
    }
  }

  // Requests the gateway answers directly, with no end-to-end encryption by design:
  // public Marketplace listings and the opt-in AI assistant.
  void relay_request(const J &r, const std::string &t) {
    J req;
    if (t == "getListings") req = {{"t", "market_list"}, {"q", r.value("query", "")}};
    else if (t == "deleteListing") req = {{"t", "market_delete"}, {"id", r.at("id")}};
    else if (t == "postListing")
      req = {{"t", "market_post"},
             {"title", r.at("title")},
             {"price", r.at("price")},
             {"description", r.value("description", "")},
             {"category", r.value("category", "")}};
    else req = {{"t", "ai"}, {"turns", r.at("turns")}, {"system", r.value("system", "")}};
    gw(req, [this, r](const J &res) {
      if (!res.value("ok", false)) return fail(r, res.value("error", "failed"));
      J out = res;
      out.erase("t");
      out.erase("rid");
      ok(r, out);
    });
  }

  static std::string lower(std::string s) {
    for (auto &c : s) c = char(std::tolower(static_cast<unsigned char>(c)));
    return s;
  }

  std::string require_chat(const J &r) {
    std::string chat = r.at("chat_id");
    if (chat == kServiceChatId) throw std::runtime_error("This chat only receives messages");
    auto s = db_.prepare("SELECT state FROM chats WHERE id=?");
    s.bind(1, chat);
    if (!s.step()) throw std::runtime_error("Chat not found");
    std::string state = s.text(0);
    if (state == "left") throw std::runtime_error("You left this group");
    if (state == "request") db_.prepare("UPDATE chats SET state='active' WHERE id=?").bind(1, chat).run();
    return chat;
  }

  void send_media(const J &r) {
    std::string chat = require_chat(r);
    std::string path = r.at("path");
    std::string kind = r.value("kind", "file");
    if (kind != "image" && kind != "file") return fail(r, "Unknown media kind");
    upload_file(path, [this, r, chat, path, kind](const std::string &err, const std::string &id,
                                                  const std::string &key, int64_t size) {
      if (!err.empty()) return fail(r, err);
      J wire = {{"media_id", id},
                {"key", key},
                {"size", size},
                {"name", r.value("name", "file")},
                {"mime", r.value("mime", "application/octet-stream")},
                {"caption", r.value("caption", "")},
                {"w", r.value("w", 0)},
                {"h", r.value("h", 0)}};
      J local = wire;
      local["local_path"] = path;
      ok(r, {{"message_id", store_outgoing(chat, kind, local, "", wire)}});
    });
  }

  void download_media(const J &r) {
    std::string mid = r.at("message_id");
    if (!valid_hex_id(mid)) return fail(r, "Bad message id");
    auto s = db_.prepare("SELECT body FROM messages WHERE id=? AND deleted=0");
    s.bind(1, mid);
    if (!s.step()) return fail(r, "Message not found");
    J body = body_of(mid, s.blob(0));
    download_to(body.value("media_id", ""), body.value("key", ""), mid,
                [this, r, mid](const std::string &err, const std::string &path) {
                  if (!err.empty()) return fail(r, err);
                  // Deleted while downloading: the plaintext must not stay behind.
                  auto s2 = db_.prepare("SELECT body FROM messages WHERE id=? AND deleted=0");
                  s2.bind(1, mid);
                  if (!s2.step()) {
                    remove_cached_media(mid);
                    return fail(r, "Message not found");
                  }
                  J b = body_of(mid, s2.blob(0));
                  b["local_path"] = path;
                  db_.prepare("UPDATE messages SET body=? WHERE id=?")
                      .bind(1, aead_seal(local_key_, str_bytes(b.dump()), mid))
                      .bind(2, mid)
                      .run();
                  emit_message(mid);
                  ok(r, {{"path", path}});
                });
  }

  void mark_read(const J &r) {
    std::string chat = r.at("chat_id");
    J mids = J::array();
    auto s = db_.prepare("SELECT id FROM messages WHERE chat_id=? AND sender!=? AND status!='read' LIMIT 500");
    s.bind(1, chat).bind(2, me_.id());
    while (s.step()) mids.push_back(s.text(0));
    db_.prepare("UPDATE messages SET status='read' WHERE chat_id=? AND sender!=?").bind(1, chat).bind(2, me_.id()).run();
    db_.prepare("UPDATE chats SET unread=0 WHERE id=?").bind(1, chat).run();
    auto st = db_.prepare("SELECT state FROM chats WHERE id=?");
    st.bind(1, chat);
    if (!mids.empty() && st.step() && st.text(0) == "active") {
      enqueue_chat(chat, {{"k", "rcpt"}, {"st", "read"}, {"mids", mids}});
      flush_outbox();
    }
    emit_chat(chat);
    ok(r);
  }

  void broadcast_group(const std::string &chat, const std::string &title, const std::set<std::string> &to,
                       const std::set<std::string> &members, int64_t ver) {
    J list = J::array();
    for (auto &m : members) list.push_back(m);
    auto c = db_.prepare("SELECT creator,salt FROM chats WHERE id=?");
    c.bind(1, chat);
    std::string creator, salt;
    if (c.step()) {
      creator = c.text(0);
      salt = c.text(1);
    }
    J p = {{"k", "group"}, {"conv", chat}, {"title", title}, {"admin", me_.id()}, {"members", list}, {"ver", ver}, {"creator", creator}, {"salt", salt}};
    for (auto &u : to)
      if (u != me_.id()) enqueue(u, p);
    flush_outbox();
  }

  void create_group(const J &r) {
    std::string title = r.at("title");
    if (title.empty()) return fail(r, "Group needs a name");
    std::set<std::string> members{me_.id()};
    for (const auto &u : r.at("members")) {
      std::string id = u;
      if (!valid_user_id(id)) return fail(r, "Invalid member");
      members.insert(id);
    }
    if (members.size() < 2) return fail(r, "Add at least one member");
    std::string salt = random_id();
    std::string chat = "g:" + group_id_for(me_.id(), salt);
    ensure_chat(chat, "group", "active");
    db_.prepare("UPDATE chats SET title=?,admin=?,version=1,creator=?,salt=? WHERE id=?")
        .bind(1, title)
        .bind(2, me_.id())
        .bind(3, me_.id())
        .bind(4, salt)
        .bind(5, chat)
        .run();
    set_members(chat, members);
    broadcast_group(chat, title, members, members, 1);
    emit_chat(chat);
    ok(r, {{"chat", chat_json(chat)}});
  }

  void update_group(const J &r) {
    std::string chat = r.at("chat_id");
    auto s = db_.prepare("SELECT title,admin,version,creator FROM chats WHERE id=? AND type='group'");
    s.bind(1, chat);
    if (!s.step()) return fail(r, "Group not found");
    if (s.text(1) != me_.id()) return fail(r, "Only the group admin can do this");
    std::string title = r.value("title", s.text(0));
    int64_t ver = s.i64(2) + 1;
    std::set<std::string> old_members, members;
    auto ms = db_.prepare("SELECT user_id FROM members WHERE chat_id=?");
    ms.bind(1, chat);
    while (ms.step()) old_members.insert(ms.text(0));
    if (r.contains("members")) {
      members.insert(me_.id());
      for (const auto &u : r["members"]) {
        std::string id = u;
        if (!valid_user_id(id)) return fail(r, "Invalid member");
        members.insert(id);
      }
      // Someone new can only verify an invite from the creator; see on_group.
      bool adds = std::any_of(members.begin(), members.end(), [&](const std::string &m) { return !old_members.count(m); });
      if (adds && s.text(3) != me_.id()) return fail(r, "Only the group's creator can add new people");
    } else {
      members = old_members;
    }
    db_.prepare("UPDATE chats SET title=?,version=? WHERE id=?").bind(1, title).bind(2, ver).bind(3, chat).run();
    set_members(chat, members);
    std::set<std::string> to = old_members;
    to.insert(members.begin(), members.end());  // removed members must learn they are out
    broadcast_group(chat, title, to, members, ver);
    emit_chat(chat);
    ok(r, {{"chat", chat_json(chat)}});
  }

  void publish_story(const J &r, const J &content) {
    std::string id = random_id();
    int64_t ts = now_ms();
    db_.prepare("INSERT INTO stories(id,sender,body,ts,seen) VALUES(?,?,?,?,1)")
        .bind(1, id)
        .bind(2, me_.id())
        .bind(3, aead_seal(local_key_, str_bytes(content.dump()), id))
        .bind(4, ts)
        .run();
    J wire = content;
    wire.erase("local_path");
    J p = {{"k", "story"}, {"id", id}, {"content", wire}, {"ts", ts}};
    auto s = db_.prepare("SELECT id FROM chats WHERE type='direct' AND state='active'");
    std::vector<std::string> peers;
    while (s.step()) peers.push_back(s.text(0).substr(2));
    for (auto &peer : peers) enqueue(peer, p);
    flush_outbox();
    emit({{"@type", "updateStories"}});
    ok(r, {{"story_id", id}});
  }

  void post_story(const J &r) {
    if (r.contains("path")) {
      std::string path = r["path"];
      upload_file(path, [this, r, path](const std::string &err, const std::string &id, const std::string &key, int64_t) {
        if (!err.empty()) return fail(r, err);
        publish_story(r, {{"kind", "image"}, {"media_id", id}, {"key", key}, {"caption", r.value("caption", "")}, {"local_path", path}});
      });
    } else {
      std::string text = r.at("text");
      if (text.empty()) return fail(r, "Story is empty");
      publish_story(r, {{"kind", "text"}, {"text", text}, {"color", r.value("color", 0)}});
    }
  }

  uintmax_t story_cache_bytes() {
    namespace fs = std::filesystem;
    uintmax_t total = 0;
    std::error_code ec;
    for (const auto &e : fs::directory_iterator(dir_ + "/media", ec)) {
      if (e.path().filename().string().rfind("story_", 0) == 0) total += e.file_size(ec) == uintmax_t(-1) ? 0 : e.file_size(ec);
    }
    return total;
  }

  void get_stories(const J &r) {
    int64_t cutoff = now_ms() - kStoryTtlMs;
    {
      auto old = db_.prepare("SELECT id FROM stories WHERE ts<?");
      old.bind(1, cutoff);
      while (old.step()) remove_cached_media("story_" + old.text(0));
    }
    db_.prepare("DELETE FROM stories WHERE ts<?").bind(1, cutoff).run();
    J out = J::array();
    auto s = db_.prepare("SELECT id,sender,body,ts,seen FROM stories ORDER BY ts");
    while (s.step()) {
      std::string id = s.text(0);
      J content = clean_story(body_of(id, s.blob(2)), true);
      if (content.is_null()) continue;
      out.push_back({{"id", id},
                     {"sender", user_json(s.text(1))},
                     {"content", content},
                     {"ts", s.i64(3)},
                     {"seen", s.i64(4) != 0}});
    }
    ok(r, {{"stories", out}});
    // Fetch image bodies lazily so a list refresh stays cheap. A few at a time, up to
    // a total: each one finishing triggers another refresh, which picks up the rest.
    uintmax_t cached = story_cache_bytes();
    for (const auto &st : out) {
      const J &c = st["content"];
      if (c.value("kind", "") != "image" || c.contains("local_path")) continue;
      if (story_downloads_.size() >= kMaxStoryDownloads || cached >= kMaxStoryCacheBytes) break;
      std::string id = st["id"];
      if (!story_downloads_.insert(id).second) continue;
      download_to(c.value("media_id", ""), c.value("key", ""), "story_" + id,
                  [this, id](const std::string &err, const std::string &path) {
                    story_downloads_.erase(id);
                    if (!err.empty()) return;
                    auto q = db_.prepare("SELECT body FROM stories WHERE id=?");
                    q.bind(1, id);
                    if (!q.step()) {
                      remove_cached_media("story_" + id);
                      return;
                    }
                    J b = body_of(id, q.blob(0));
                    b["local_path"] = path;
                    db_.prepare("UPDATE stories SET body=? WHERE id=?")
                        .bind(1, aead_seal(local_key_, str_bytes(b.dump()), id))
                        .bind(2, id)
                        .run();
                    emit({{"@type", "updateStories"}});
                  });
    }
  }

  // ---- state ----------------------------------------------------------------
  std::string dir_;
  Key32 local_key_;
  Db db_;
  Identity me_;
  Endpoint ep_;
  int wake_[2] = {-1, -1};
  std::atomic<bool> running_{true};
  std::thread worker_;

  std::mutex helper_m_;
  std::condition_variable helper_cv_;
  int helpers_ = 0;

  std::mutex in_m_;
  std::deque<std::function<void()>> in_;
  std::mutex out_m_;
  std::condition_variable out_cv_;
  std::deque<std::string> out_;

  std::shared_ptr<WebSocket> ws_;
  bool connecting_ = false, authed_ = false, auth_blocked_ = false;
  std::string auth_token_, auth_phone_, auth_code_, auth_ticket_;
  int retry_ = 0;
  int64_t next_connect_ = 0, last_rx_ = 0, rid_ = 0;
  std::string state_ = "connecting";
  std::map<std::string, Cb> pending_;
  std::set<int64_t> inflight_;
  std::set<std::string> key_requests_;
  std::set<std::string> story_downloads_;
};

}  // namespace sync_core

extern "C" {

void *sync_client_create(const char *dir, const char *key_hex, const char *url) {
  try {
    auto key = sync_core::key_from_hex(key_hex ? key_hex : "");
    if (!dir || !url || !key) return nullptr;
    return new sync_core::Client(dir, *key, url);
  } catch (...) {
    return nullptr;
  }
}

void sync_client_send(void *c, const char *json) {
  if (c && json) static_cast<sync_core::Client *>(c)->send(json);
}

char *sync_client_receive(void *c, double timeout) {
  return c ? static_cast<sync_core::Client *>(c)->receive(timeout) : nullptr;
}

void sync_string_free(char *s) { free(s); }

void sync_client_destroy(void *c) { delete static_cast<sync_core::Client *>(c); }

}  // extern "C"
