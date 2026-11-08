// Unit tests for crypto, plus an end-to-end test against a live gateway when
// SYNC_TEST_GATEWAY=ws://host:port is set.
#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <functional>
#include <string>
#include <thread>
#include <vector>

#include <arpa/inet.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>

#include <future>
#include <sstream>

#include "crypto.h"
#include "db.h"
#include "json.hpp"
#include "net.h"
#include "sync_core.h"

// The regression tests drive the real handlers with frames a hostile relay or peer
// could send, on the worker thread, with no gateway attached.
#define private public
#include "client.cpp"
#undef private

using namespace sync_core;
using J = nlohmann::json;

static int failures = 0;
#define CHECK(c)                                              \
  do {                                                        \
    if (!(c)) {                                               \
      std::printf("FAIL %s:%d %s\n", __FILE__, __LINE__, #c); \
      failures++;                                             \
    }                                                         \
  } while (0)

static Identity fresh() {
  Key32 seed;
  random_bytes(seed.data(), 32);
  return Identity::from_seed(seed);
}

static void test_crypto() {
  Identity a = fresh(), b = fresh(), eve = fresh();
  Bytes pt = str_bytes("salom dunyo");
  Bytes env = seal(a, b.id(), b.box_pk, pt);
  auto got = open(b, a.id(), a.box_pk, env);
  CHECK(got && *got == pt);

  CHECK(!open(eve, a.id(), a.box_pk, env));      // wrong recipient
  CHECK(!open(b, eve.id(), eve.box_pk, env));    // forged sender
  CHECK(!open(b, eve.id(), a.box_pk, env));      // wrong claimed sender id
  Bytes bad = env;
  bad.back() ^= 1;
  CHECK(!open(b, a.id(), a.box_pk, bad));        // tampered ciphertext
  bad = env;
  bad[1] ^= 1;
  CHECK(!open(b, a.id(), a.box_pk, bad));        // tampered ephemeral key
  CHECK(seal(a, b.id(), b.box_pk, pt) != env);   // fresh randomness per message
  CHECK(!open(b, a.id(), a.box_pk, Bytes(10)));  // short input

  CHECK(verify_box_key(a.id(), a.box_pk, a.box_signature()));
  CHECK(!verify_box_key(eve.id(), a.box_pk, a.box_signature()));
  CHECK(!verify_box_key(a.id(), eve.box_pk, a.box_signature()));

  Key32 k;
  random_bytes(k.data(), 32);
  auto sealed = aead_seal(k, pt, "ad");
  CHECK(aead_open(k, sealed, "ad") == pt);
  CHECK(!aead_open(k, sealed, "other"));

  CHECK(safety_number(a.id(), b.id()) == safety_number(b.id(), a.id()));
  CHECK(safety_number(a.id(), b.id()) != safety_number(a.id(), eve.id()));

  for (std::string s : {"", "f", "fo", "foo", "foob", "fooba", "foobar"})
    CHECK(b64_decode(b64_encode(str_bytes(s))) == str_bytes(s));
  CHECK(!b64_decode("a!b="));
  CHECK(!parse_ws_url("http://x:1"));
  CHECK(parse_ws_url("wss://x")->port == "443");
  CHECK(parse_ws_url("ws://x:81")->port == "81");

  // RFC 8032 test 1: proves signatures interoperate with the Go gateway's Ed25519.
  auto seed = key_from_hex("9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60");
  Identity v = Identity::from_seed(*seed);
  CHECK(v.id() == "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a");
  CHECK(to_hex(v.sign({})) ==
        "e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b");
}

struct Peer {
  void *c;
  std::vector<J> seen;
  int extra = 0;
  Peer(const std::string &dir, const std::string &url) {
    std::filesystem::create_directories(dir);
    Key32 k;
    random_bytes(k.data(), 32);
    c = sync_client_create(dir.c_str(), to_hex(k).c_str(), url.c_str());
    CHECK(c != nullptr);
  }
  ~Peer() { sync_client_destroy(c); }
  void pump(double t) {
    if (char *s = sync_client_receive(c, t)) {
      seen.push_back(J::parse(s));
      sync_string_free(s);
    }
  }
  bool wait(const std::function<bool(const J &)> &pred, int seconds = 10) {
    size_t i = 0;
    auto end = std::chrono::steady_clock::now() + std::chrono::seconds(seconds);
    while (std::chrono::steady_clock::now() < end) {
      for (; i < seen.size(); i++)
        if (pred(seen[i])) return true;
      pump(0.1);
    }
    return false;
  }
  J call(J req) {
    int id = ++extra;
    req["@extra"] = id;
    sync_client_send(c, req.dump().c_str());
    size_t mark = 0;
    auto end = std::chrono::steady_clock::now() + std::chrono::seconds(15);
    while (std::chrono::steady_clock::now() < end) {
      for (; mark < seen.size(); mark++)
        if (seen[mark].value("@extra", 0) == id) return seen[mark];
      pump(0.1);
    }
    return J{{"@type", "error"}, {"message", "timeout"}};
  }
  void clear() { seen.clear(); }
};

static bool is_update(const J &e, const char *type) { return e.value("@type", "") == type; }

static bool msg_status(const J &e, const std::string &id, const std::string &st) {
  return is_update(e, "updateMessage") && e["message"].value("id", "") == id &&
         e["message"].value("status", "") == st;
}

// Returns false when the gateway refused to register the test identities, so the
// caller does not report a run that did not happen.
static bool test_e2e(const std::string &url) {
  auto root = std::filesystem::temp_directory_path() / ("sync_e2e_" + random_id());
  auto ready = [](const J &e) { return is_update(e, "updateConnection") && e.value("state", "") == "ready"; };
  std::string suffix = random_id().substr(0, 8);
  std::string ua = "alice" + suffix, ub = "bob" + suffix;
  {
    Peer a((root / "a").string(), url), b((root / "b").string(), url);
    if (!a.wait(ready)) {
      // A gateway that requires a verified phone number cannot register a test
      // identity. Say so instead of failing every later step.
      bool unverified = std::any_of(a.seen.begin(), a.seen.end(), [](const J &e) {
        return e.value("@type", "") == "updateConnection" && e.value("state", "") == "unverified";
      });
      std::printf(unverified ? "e2e skipped: this gateway requires a verified phone number\n"
                             : "e2e skipped: could not reach %s\n",
                  url.c_str());
      std::filesystem::remove_all(root);
      return false;
    }
    CHECK(b.wait(ready));
    std::string a_id = a.call({{"@type", "getMe"}})["me"]["id"];
    std::string b_id = b.call({{"@type", "getMe"}})["me"]["id"];
    CHECK(a.call({{"@type", "setProfile"}, {"username", ua}, {"display_name", "Alice"}})["@type"] == "ok");
    CHECK(b.call({{"@type", "setProfile"}, {"username", ub}, {"display_name", "Bob"}})["@type"] == "ok");
    CHECK(b.call({{"@type", "setProfile"}, {"username", ua}, {"display_name", "Bob"}})["@type"] == "error");  // taken

    J found = a.call({{"@type", "searchUsers"}, {"query", ub}});
    CHECK(found["users"].size() == 1 && found["users"][0]["id"] == b_id);

    std::string chat = "u:" + b_id;
    CHECK(a.call({{"@type", "openDirectChat"}, {"user_id", b_id}})["@type"] == "ok");
    std::string mid = a.call({{"@type", "sendMessage"}, {"chat_id", chat}, {"text", "salom"}}).value("message_id", "");

    CHECK(b.wait([&](const J &e) {
      return is_update(e, "updateNewMessage") && e["message"]["content"].value("text", "") == "salom";
    }));
    // An unknown sender lands in requests and gets no receipts until accepted.
    J reqs = b.call({{"@type", "getChats"}, {"filter", "requests"}});
    CHECK(reqs["chats"].size() == 1 && reqs["chats"][0]["unread"] == 1);
    CHECK(a.wait([&](const J &e) { return msg_status(e, mid, "sent"); }));
    std::string b_chat = "u:" + a_id;
    CHECK(b.call({{"@type", "acceptRequest"}, {"chat_id", b_chat}})["@type"] == "ok");
    CHECK(b.call({{"@type", "markRead"}, {"chat_id", b_chat}})["@type"] == "ok");
    CHECK(a.wait([&](const J &e) { return msg_status(e, mid, "read"); }));

    // Reaction, edit, delete.
    a.clear();
    CHECK(b.call({{"@type", "react"}, {"message_id", mid}, {"emoji", "👋"}})["@type"] == "ok");
    CHECK(a.wait([&](const J &e) { return is_update(e, "updateMessage") && e["message"]["reactions"].size() == 1; }));
    b.clear();
    CHECK(a.call({{"@type", "editMessage"}, {"message_id", mid}, {"text", "salom!"}})["@type"] == "ok");
    CHECK(b.wait([&](const J &e) {
      return is_update(e, "updateMessage") && e["message"].value("edited", false) &&
             e["message"]["content"].value("text", "") == "salom!";
    }));
    CHECK(b.call({{"@type", "editMessage"}, {"message_id", mid}, {"text", "hack"}})["@type"] == "error");
    std::string doomed = a.call({{"@type", "sendMessage"}, {"chat_id", chat}, {"text", "bye"}}).value("message_id", "");
    CHECK(b.wait([&](const J &e) { return is_update(e, "updateNewMessage") && e["message"]["id"] == doomed; }));
    b.clear();
    CHECK(a.call({{"@type", "deleteMessage"}, {"message_id", doomed}})["@type"] == "ok");
    CHECK(b.wait([&](const J &e) { return is_update(e, "updateMessage") && e["message"]["id"] == doomed && e["message"].value("deleted", false); }));

    // Typing is transient.
    b.clear();
    a.call({{"@type", "setTyping"}, {"chat_id", chat}});
    CHECK(b.wait([&](const J &e) { return is_update(e, "updateTyping"); }));

    // Encrypted media round trip.
    std::filesystem::create_directories(root);
    auto file = root / "photo.bin";
    { std::ofstream(file, std::ios::binary) << std::string(200000, 'x'); }
    b.clear();
    J media = a.call({{"@type", "sendMedia"}, {"chat_id", chat}, {"path", file.string()}, {"kind", "image"}, {"name", "p.bin"}});
    CHECK(media["@type"] == "ok");
    std::string media_mid = media.value("message_id", "");
    CHECK(b.wait([&](const J &e) { return is_update(e, "updateNewMessage") && e["message"]["id"] == media_mid; }));
    J dl = b.call({{"@type", "downloadMedia"}, {"message_id", media_mid}});
    CHECK(dl["@type"] == "ok");
    std::error_code ec;
    CHECK(std::filesystem::file_size(dl.value("path", "/nonexistent"), ec) == 200000);

    // Group: creation, messaging, admin-only rules, removal.
    b.clear();
    J group = a.call({{"@type", "createGroup"}, {"title", "Team"}, {"members", J::array({b_id})}});
    std::string g = group["chat"]["id"];
    CHECK(b.wait([&](const J &e) { return is_update(e, "updateChat") && e["chat"]["id"] == g && e["chat"]["title"] == "Team"; }));
    CHECK(b.call({{"@type", "updateGroup"}, {"chat_id", g}, {"title", "Hijack"}})["@type"] == "error");
    CHECK(b.call({{"@type", "acceptRequest"}, {"chat_id", g}})["@type"] == "ok");
    a.clear();
    CHECK(b.call({{"@type", "sendMessage"}, {"chat_id", g}, {"text", "group hi"}})["@type"] == "ok");
    CHECK(a.wait([&](const J &e) { return is_update(e, "updateNewMessage") && e["message"]["chat_id"] == g; }));

    // Poll.
    b.clear();
    std::string pid = a.call({{"@type", "sendPoll"}, {"chat_id", g}, {"question", "Qachon?"}, {"options", J::array({"Bugun", "Ertaga"})}}).value("message_id", "");
    CHECK(b.wait([&](const J &e) { return is_update(e, "updateNewMessage") && e["message"]["id"] == pid; }));
    a.clear();
    CHECK(b.call({{"@type", "votePoll"}, {"message_id", pid}, {"option", 1}})["@type"] == "ok");
    CHECK(a.wait([&](const J &e) { return is_update(e, "updateMessage") && e["message"]["id"] == pid && e["message"]["votes"].size() == 1; }));

    // A story reaches an accepted contact.
    b.clear();
    CHECK(a.call({{"@type", "postStory"}, {"text", "kun yaxshi"}})["@type"] == "ok");
    CHECK(b.wait([&](const J &e) { return is_update(e, "updateStories"); }));
    J stories = b.call({{"@type", "getStories"}});
    CHECK(stories["stories"].size() == 1 && stories["stories"][0]["content"]["text"] == "kun yaxshi");

    // Search decrypts locally.
    J hits = b.call({{"@type", "searchMessages"}, {"query", "GROUP"}});
    CHECK(hits["messages"].size() == 1);

    // Removal tells the removed member.
    b.clear();
    CHECK(a.call({{"@type", "updateGroup"}, {"chat_id", g}, {"members", J::array()}})["@type"] == "ok");
    CHECK(b.wait([&](const J &e) { return is_update(e, "updateChat") && e["chat"]["id"] == g && e["chat"]["state"] == "left"; }));
    CHECK(b.call({{"@type", "sendMessage"}, {"chat_id", g}, {"text", "still here"}})["@type"] == "error");

    // Blocking drops the sender's messages.
    CHECK(b.call({{"@type", "setBlocked"}, {"user_id", a_id}, {"blocked", true}})["@type"] == "ok");
    b.clear();
    a.call({{"@type", "sendMessage"}, {"chat_id", chat}, {"text", "blocked"}});
    CHECK(!b.wait([&](const J &e) { return is_update(e, "updateNewMessage"); }, 2));
  }

  // Offline delivery: b is down while a2 sends, and gets it on reconnect from its stored db.
  {
    std::string dira = (root / "a2").string(), dirb = (root / "b2").string();
    Key32 kb;
    random_bytes(kb.data(), 32);
    std::filesystem::create_directories(dirb);
    std::string bid;
    {
      void *bc = sync_client_create(dirb.c_str(), to_hex(kb).c_str(), url.c_str());
      sync_client_send(bc, R"({"@type":"getMe","@extra":1})");
      for (int i = 0; i < 200 && bid.empty(); i++) {
        if (char *s = sync_client_receive(bc, 0.1)) {
          J e = J::parse(s);
          sync_string_free(s);
          if (e.value("@extra", 0) == 1) bid = e["me"]["id"];
        }
      }
      std::this_thread::sleep_for(std::chrono::seconds(1));  // let it register with the gateway
      sync_client_destroy(bc);
    }
    Peer a2(dira, url);
    CHECK(a2.wait(ready));
    a2.call({{"@type", "openDirectChat"}, {"user_id", bid}});
    J s = a2.call({{"@type", "sendMessage"}, {"chat_id", "u:" + bid}, {"text", "offline salom"}});
    CHECK(a2.wait([&](const J &e) { return msg_status(e, s.value("message_id", ""), "sent"); }));

    void *bc = sync_client_create(dirb.c_str(), to_hex(kb).c_str(), url.c_str());
    CHECK(bc != nullptr);
    bool got = false;
    for (int i = 0; i < 100 && !got; i++) {
      if (char *m = sync_client_receive(bc, 0.1)) {
        J e = J::parse(m);
        sync_string_free(m);
        got = is_update(e, "updateNewMessage") && e["message"]["content"].value("text", "") == "offline salom";
      }
    }
    CHECK(got);
    sync_client_destroy(bc);

    // The wrong local key must not open the database.
    Key32 wrong;
    random_bytes(wrong.data(), 32);
    CHECK(sync_client_create(dirb.c_str(), to_hex(wrong).c_str(), url.c_str()) == nullptr);
  }
  std::filesystem::remove_all(root);
  return true;
}

// A client with no gateway, fed frames directly.
struct Bench {
  std::string dir;
  Client *c;
  explicit Bench(const std::string &d) : dir(d) {
    std::filesystem::create_directories(d);
    Key32 k;
    random_bytes(k.data(), 32);
    c = new Client(d, k, "ws://127.0.0.1:1");
  }
  ~Bench() { delete c; }
  template <class F>
  auto on(F f) {
    std::promise<decltype(f())> pr;
    auto fut = pr.get_future();
    c->post([&] { pr.set_value(f()); });
    return fut.get();
  }
  std::string me() {
    return on([&] { return c->me_.id(); });
  }
  Key32 me_box() {
    return on([&] { return c->me_.box_pk; });
  }
  J call(J req) {
    static int extra = 1000;
    int id = ++extra;
    req["@extra"] = id;
    c->send(req.dump());
    for (int i = 0; i < 100; i++) {
      char *s = c->receive(0.1);
      if (!s) continue;
      J e = J::parse(s);
      free(s);
      if (e.value("@extra", 0) == id) return e;
    }
    return {{"@type", "timeout"}};
  }
  int64_t count(const std::string &sql) {
    return on([&] {
      auto s = c->db_.prepare(sql.c_str());
      return s.step() ? s.i64(0) : int64_t(-1);
    });
  }
  std::string text(const std::string &sql) {
    return on([&] {
      auto s = c->db_.prepare(sql.c_str());
      return s.step() ? s.text(0) : std::string("<none>");
    });
  }
  void frame(const std::string &raw) {
    on([&] {
      c->handle_frame(raw);
      return 0;
    });
  }
};

static std::string peer_frame(const Identity &from, Bench &b, J payload, bool stamp = true) {
  if (stamp) {
    if (!payload.contains("eid")) payload["eid"] = random_id();
    if (!payload.contains("sent")) payload["sent"] = now_ms();
  }
  Bytes blob = seal(from, b.me(), b.me_box(), str_bytes(payload.dump()));
  J sender = {{"id", from.id()}, {"box_pk", to_hex(from.box_pk)}, {"box_sig", to_hex(from.box_signature())},
              {"username", "peer"}, {"display_name", "Peer"}};
  return J{{"t", "msg"}, {"seq", 1}, {"from", from.id()}, {"blob", b64_encode(blob)}, {"sender", sender}}.dump();
}

static std::string mid_of(int n) {
  char buf[33];
  std::snprintf(buf, sizeof buf, "%032x", n);
  return buf;
}

static J group_payload(const Identity &creator, const std::string &salt, std::vector<std::string> members, int64_t ver = 1) {
  return {{"k", "group"}, {"conv", "g:" + group_id_for(creator.id(), salt)}, {"title", "Team"}, {"admin", creator.id()},
          {"members", members}, {"ver", ver}, {"creator", creator.id()}, {"salt", salt}};
}

static void test_handlers(const std::filesystem::path &root) {
  Identity peer = fresh(), other = fresh();
  std::string salt = random_id();
  std::string G = "g:" + group_id_for(peer.id(), salt);

  // Deep JSON from a peer is dropped, and does not take the process down.
  {
    Bench b((root / "deep").string());
    std::string deep(500000, '[');
    deep += std::string(500000, ']');
    std::string raw = J{{"k", "msg"}, {"mid", mid_of(1)}, {"kind", "text"}}.dump();
    raw.pop_back();
    raw += ",\"content\":" + deep + ",\"eid\":\"" + random_id() + "\",\"sent\":" + std::to_string(now_ms()) + "}";
    Bytes blob = seal(peer, b.me(), b.me_box(), str_bytes(raw));
    J sender = {{"id", peer.id()}, {"box_pk", to_hex(peer.box_pk)}, {"box_sig", to_hex(peer.box_signature())}};
    b.frame(J{{"t", "msg"}, {"seq", 1}, {"from", peer.id()}, {"blob", b64_encode(blob)}, {"sender", sender}}.dump());
    CHECK(b.count("SELECT COUNT(*) FROM messages") == 0);
    std::string gw_deep = "{\"t\":\"x\",\"y\":" + deep + "}";
    b.frame(gw_deep);  // the same from the gateway itself
  }

  // Non-string fields and a self-reply no longer break list reads.
  {
    Bench b((root / "poison").string());
    std::string m = mid_of(2), key(64, 'a');
    b.frame(peer_frame(peer, b, {{"k", "msg"}, {"mid", m}, {"kind", "image"}, {"reply_to", m},
                                 {"content", {{"media_id", m}, {"key", key}, {"text", 123}, {"w", "big"}, {"name", 5}}}}));
    CHECK(b.count("SELECT COUNT(*) FROM messages") == 1);
    J chats = b.call({{"@type", "getChats"}, {"filter", "requests"}});
    CHECK(chats["@type"] == "ok" && chats["chats"].size() == 1);
    J msgs = b.call({{"@type", "getMessages"}, {"chat_id", "u:" + peer.id()}});
    CHECK(msgs["@type"] == "ok" && msgs["messages"].size() == 1);
    const J &content = msgs["messages"][0]["content"];
    CHECK(!content.contains("text") && content["w"] == 0 && content["name"] == "");
    // A peer cannot name a local file.
    std::string m2 = mid_of(3);
    b.frame(peer_frame(peer, b, {{"k", "msg"}, {"mid", m2}, {"kind", "image"},
                                 {"content", {{"media_id", m2}, {"key", key}, {"local_path", "/etc/passwd"}}}}));
    J again = b.call({{"@type", "getMessages"}, {"chat_id", "u:" + peer.id()}});
    CHECK(!again["messages"][0]["content"].contains("local_path"));
  }

  // Replay: same bytes twice. Edits, leaves and deleted chats stay as they are.
  {
    Bench b((root / "replay").string());
    std::string m = mid_of(4), chat = "u:" + peer.id();
    b.frame(peer_frame(peer, b, {{"k", "msg"}, {"mid", m}, {"kind", "text"}, {"content", {{"text", "v1"}}}}));
    std::string v2 = peer_frame(peer, b, {{"k", "edit"}, {"mid", m}, {"text", "v2"}, {"sent", now_ms()}});
    std::this_thread::sleep_for(std::chrono::milliseconds(2));
    std::string v3 = peer_frame(peer, b, {{"k", "edit"}, {"mid", m}, {"text", "v3"}, {"sent", now_ms()}});
    b.frame(v2);
    b.frame(v3);
    b.frame(v2);
    J msgs = b.call({{"@type", "getMessages"}, {"chat_id", chat}});
    CHECK(msgs["messages"][0]["content"]["text"] == "v3");

    // Reordered rather than replayed: an older edit arriving late also loses.
    std::string m7 = mid_of(7);
    b.frame(peer_frame(peer, b, {{"k", "msg"}, {"mid", m7}, {"kind", "text"}, {"content", {{"text", "a"}}}}));
    b.frame(peer_frame(peer, b, {{"k", "edit"}, {"mid", m7}, {"text", "new"}, {"sent", now_ms() + 5}}));
    b.frame(peer_frame(peer, b, {{"k", "edit"}, {"mid", m7}, {"text", "old"}, {"sent", now_ms() - 5000}}));
    CHECK(b.call({{"@type", "getMessages"}, {"chat_id", chat}})["messages"][0]["content"]["text"] == "new");

    std::string once = peer_frame(peer, b, {{"k", "msg"}, {"mid", mid_of(5)}, {"kind", "text"}, {"content", {{"text", "once"}}}});
    b.frame(once);
    CHECK(b.count("SELECT COUNT(*) FROM messages WHERE id='" + mid_of(5) + "'") == 1);
    CHECK(b.call({{"@type", "deleteChat"}, {"chat_id", chat}})["@type"] == "ok");
    b.frame(once);
    CHECK(b.count("SELECT COUNT(*) FROM messages") == 0);

    // Too old, or with no freshness fields at all: refused.
    b.frame(peer_frame(peer, b, {{"k", "msg"}, {"mid", mid_of(6)}, {"kind", "text"}, {"content", {{"text", "x"}}},
                                 {"sent", now_ms() - kEnvelopeMaxAgeMs - 1000}}));
    b.frame(peer_frame(peer, b, {{"k", "msg"}, {"mid", mid_of(8)}, {"kind", "text"}, {"content", {{"text", "x"}}}}, false));
    CHECK(b.count("SELECT COUNT(*) FROM messages") == 0);

    // State changes cannot arrive through the unqueued transient path.
    Bytes blob = seal(peer, b.me(), b.me_box(),
                      str_bytes(J{{"k", "msg"}, {"mid", mid_of(9)}, {"kind", "text"}, {"content", {{"text", "t"}}},
                                  {"eid", random_id()}, {"sent", now_ms()}}.dump()));
    b.frame(J{{"t", "transient"}, {"from", peer.id()}, {"blob", b64_encode(blob)}}.dump());
    CHECK(b.count("SELECT COUNT(*) FROM messages") == 0);
  }

  // Group ids are bound to their creator.
  {
    Bench b((root / "squat").string());
    std::string me = b.me();
    // A squatter cannot claim the real creator's id, under any spelling of it.
    J claim = group_payload(peer, salt, {peer.id(), me, other.id()});
    claim["admin"] = other.id();
    b.frame(peer_frame(other, b, claim));
    J claim2 = claim;
    claim2["creator"] = other.id();
    b.frame(peer_frame(other, b, claim2));
    CHECK(b.count("SELECT COUNT(*) FROM chats WHERE type NOT IN ('saved','service')") == 0);
    b.frame(peer_frame(peer, b, group_payload(peer, salt, {peer.id(), me, other.id()})));
    CHECK(b.text("SELECT admin FROM chats WHERE id='" + G + "'") == peer.id());
    // Still true once the chat is deleted locally.
    CHECK(b.call({{"@type", "deleteChat"}, {"chat_id", G}})["@type"] == "ok");
    b.frame(peer_frame(other, b, claim));
    CHECK(b.count("SELECT COUNT(*) FROM chats WHERE type NOT IN ('saved','service')") == 0);
    // Only the current admin can change it afterwards, and not by a huge version jump.
    b.frame(peer_frame(peer, b, group_payload(peer, salt, {peer.id(), me, other.id()})));
    J hijack = group_payload(peer, salt, {other.id(), me}, 9);
    hijack["admin"] = other.id();
    b.frame(peer_frame(other, b, hijack));
    CHECK(b.text("SELECT admin FROM chats WHERE id='" + G + "'") == peer.id());
    b.frame(peer_frame(peer, b, group_payload(peer, salt, {peer.id(), me}, 999999)));
    CHECK(b.count("SELECT version FROM chats WHERE id='" + G + "'") == 1);
  }

  // A group that omits me does not exist for me, so it cannot skip the request inbox.
  {
    Bench b((root / "inbox").string());
    std::string s2 = random_id(), g2 = "g:" + group_id_for(peer.id(), s2);
    b.frame(peer_frame(peer, b, group_payload(peer, s2, {peer.id(), other.id()})));
    CHECK(b.count("SELECT COUNT(*) FROM chats WHERE type NOT IN ('saved','service')") == 0);
    b.frame(peer_frame(peer, b, {{"k", "msg"}, {"conv", g2}, {"mid", mid_of(10)}, {"kind", "text"}, {"content", {{"text", "spam"}}}}));
    CHECK(b.count("SELECT COUNT(*) FROM messages") == 0);
    CHECK(b.call({{"@type", "getChats"}, {"filter", "main"}})["chats"].size() == 1);
  }

  // Removal ends every mutation, and a stale leave no longer applies.
  {
    Bench b((root / "removed").string());
    std::string me = b.me(), s3 = random_id();
    Identity admin = fresh();
    std::string g3 = "g:" + group_id_for(admin.id(), s3);
    b.frame(peer_frame(admin, b, group_payload(admin, s3, {admin.id(), me, peer.id()})));
    std::string m1 = mid_of(11), m2 = mid_of(12);
    b.frame(peer_frame(peer, b, {{"k", "msg"}, {"conv", g3}, {"mid", m1}, {"kind", "text"}, {"content", {{"text", "orig"}}}}));
    b.frame(peer_frame(peer, b, {{"k", "msg"}, {"conv", g3}, {"mid", m2}, {"kind", "text"}, {"content", {{"text", "keep"}}}}));
    std::string stale_leave = peer_frame(peer, b, {{"k", "leave"}, {"conv", g3}, {"ver", 1}});
    b.frame(peer_frame(admin, b, group_payload(admin, s3, {admin.id(), me}, 2)));
    b.frame(peer_frame(peer, b, {{"k", "edit"}, {"mid", m1}, {"text", "rewritten"}, {"sent", now_ms() + 1}}));
    b.frame(peer_frame(peer, b, {{"k", "del"}, {"mid", m2}}));
    J msgs = b.call({{"@type", "getMessages"}, {"chat_id", g3}});
    bool intact = msgs["messages"].size() == 2;
    for (const auto &m : msgs["messages"])
      if (m["deleted"].get<bool>() || m["edited"].get<bool>()) intact = false;
    CHECK(intact);
    b.frame(peer_frame(admin, b, group_payload(admin, s3, {admin.id(), me, peer.id()}, 3)));
    b.frame(stale_leave);
    CHECK(b.count("SELECT COUNT(*) FROM members WHERE chat_id='" + g3 + "' AND user_id='" + peer.id() + "'") == 1);
  }

  // Votes must fit the poll.
  {
    Bench b((root / "votes").string());
    std::string m = mid_of(13);
    b.frame(peer_frame(peer, b, {{"k", "msg"}, {"mid", m}, {"kind", "poll"}, {"content", {{"question", "q"}, {"options", J::array({"a", "b"})}}}}));
    b.frame(peer_frame(peer, b, {{"k", "vote"}, {"mid", m}, {"option", 99}}));
    CHECK(b.count("SELECT COUNT(*) FROM votes") == 0);
    b.frame(peer_frame(peer, b, {{"k", "vote"}, {"mid", m}, {"option", 1}}));
    CHECK(b.count("SELECT COUNT(*) FROM votes") == 1);
  }

  // Cached plaintext goes when its message or story does.
  {
    Bench b((root / "cache").string());
    auto media = [&](const std::string &name) { return std::filesystem::path(b.dir) / "media" / name; };
    auto touch = [&](const std::string &name) { std::ofstream(media(name)) << "plain"; };
    std::string key(64, 'a'), m = mid_of(14), m2 = mid_of(15), chat = "u:" + peer.id();
    b.call({{"@type", "openDirectChat"}, {"user_id", peer.id()}});
    b.frame(peer_frame(peer, b, {{"k", "msg"}, {"mid", m}, {"kind", "image"}, {"content", {{"media_id", m}, {"key", key}}}}));
    b.frame(peer_frame(peer, b, {{"k", "msg"}, {"mid", m2}, {"kind", "image"}, {"content", {{"media_id", m2}, {"key", key}}}}));
    touch(m);
    touch(m2);
    b.frame(peer_frame(peer, b, {{"k", "del"}, {"mid", m}}));
    CHECK(!std::filesystem::exists(media(m)));
    CHECK(std::filesystem::exists(media(m2)));

    std::string sid = mid_of(16);
    b.frame(peer_frame(peer, b, {{"k", "story"}, {"id", sid}, {"ts", now_ms()}, {"content", {{"kind", "text"}, {"text", "hi"}}}}));
    touch("story_" + sid);
    b.on([&] {
      b.c->db_.prepare("UPDATE stories SET ts=1").run();
      return 0;
    });
    b.call({{"@type", "getStories"}});
    CHECK(!std::filesystem::exists(media("story_" + sid)));

    // A sender cannot pile up stories without limit.
    for (int i = 0; i < 30; i++)
      b.frame(peer_frame(peer, b, {{"k", "story"}, {"id", mid_of(100 + i)}, {"ts", now_ms()}, {"content", {{"kind", "text"}, {"text", "x"}}}}));
    CHECK(b.count("SELECT COUNT(*) FROM stories") == 20);

    CHECK(b.call({{"@type", "deleteChat"}, {"chat_id", chat}})["@type"] == "ok");
    CHECK(!std::filesystem::exists(media(m2)));
  }

  // Local files are private from creation.
  {
    Bench b((root / "modes").string());
    auto perms = [](const std::string &p) { return std::filesystem::status(p).permissions(); };
    using P = std::filesystem::perms;
    CHECK((perms(b.dir + "/sync.db") & (P::group_all | P::others_all)) == P::none);
    CHECK((perms(b.dir) & (P::group_all | P::others_all)) == P::none);
  }

  // Saved messages: a chat with nobody on the other end. It must store what it is
  // given and send nothing, or a private note would leak to the gateway.
  {
    Bench b((root / "saved").string());
    // Offered from the start, unlike the service chat, because it is somewhere to
    // put things rather than somewhere Sync talks.
    J initial = b.call({{"@type", "getChats"}, {"filter", "main"}})["chats"];
    CHECK(initial.size() == 1 && initial[0]["id"] == "saved");
    J sent = b.call({{"@type", "sendMessage"}, {"chat_id", "saved"}, {"text", "a note to myself"}});
    CHECK(sent["@type"] == "ok");
    CHECK(b.count("SELECT COUNT(*) FROM messages WHERE chat_id='saved'") == 1);
    CHECK(b.count("SELECT COUNT(*) FROM outbox") == 0);
    // Now that it holds something it belongs in the list.
    J chats = b.call({{"@type", "getChats"}, {"filter", "main"}})["chats"];
    CHECK(chats.size() == 1 && chats[0]["id"] == "saved" && chats[0]["type"] == "saved");
  }

  // The service chat carries messages from Sync itself.
  {
    Bench b((root / "service").string());
    std::string sid = mid_of(77);
    b.frame(J{{"t", "service"},
              {"id", sid},
              {"kind", "security"},
              {"body", {{"text", "new_device"}, {"at", 1762000000000}, {"place", "1.2.3.4"}}},
              {"ts", now_ms()}}
                .dump());
    CHECK(b.count("SELECT COUNT(*) FROM messages WHERE chat_id='service'") == 1);
    CHECK(b.text("SELECT kind FROM messages WHERE id='" + sid + "'") == "service");
    J chats = b.call({{"@type", "getChats"}, {"filter", "main"}})["chats"];
    CHECK(chats.size() == 2);  // saved is always offered; service joined it
    CHECK((chats[0]["id"] == "service" || chats[1]["id"] == "service"));
    J msgs = b.call({{"@type", "getMessages"}, {"chat_id", "service"}, {"limit", 10}})["messages"];
    // The body names the notice; the words are the app's, so a gateway cannot put
    // sentences of its own choosing into a chat that shows a verified mark.
    CHECK(msgs.size() == 1 && msgs[0]["content"]["service"] == "new_device");
    CHECK(msgs[0]["content"]["place"] == "1.2.3.4");
    // Delivered twice, stored once.
    b.frame(J{{"t", "service"}, {"id", sid}, {"body", {{"text", "new_device"}}}, {"ts", now_ms()}}.dump());
    CHECK(b.count("SELECT COUNT(*) FROM messages WHERE chat_id='service'") == 1);
    // It only receives: nothing can be sent into it.
    CHECK(b.call({{"@type", "sendMessage"}, {"chat_id", "service"}, {"text", "hi"}})["@type"] == "error");
    // A notice with no name at all is not a message.
    b.frame(J{{"t", "service"}, {"id", mid_of(78)}, {"body", J::object()}, {"ts", now_ms()}}.dump());
    CHECK(b.count("SELECT COUNT(*) FROM messages WHERE chat_id='service'") == 1);
  }

  // A peer must never be able to write into either of Sync's own chats, whatever it
  // puts in "conv": those are not identities and not groups.
  {
    Bench b((root / "ownchats").string());
    Identity imposter = fresh();
    for (const char *target : {"service", "saved"}) {
      b.frame(peer_frame(imposter, b,
                         {{"k", "msg"},
                          {"conv", target},
                          {"mid", mid_of(91)},
                          {"kind", "text"},
                          {"content", {{"text", "trust me"}}}}));
      CHECK(b.count(std::string("SELECT COUNT(*) FROM messages WHERE chat_id='") + target + "'") == 0);
    }
  }
}

// A media server that sends far more than it should.
static void test_http_cap() {
  int srv = socket(AF_INET, SOCK_STREAM, 0);
  sockaddr_in a{};
  a.sin_family = AF_INET;
  a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  ::bind(srv, reinterpret_cast<sockaddr *>(&a), sizeof a);
  socklen_t l = sizeof a;
  getsockname(srv, reinterpret_cast<sockaddr *>(&a), &l);
  listen(srv, 4);
  std::thread t([srv] {
    for (int i = 0; i < 3; i++) {
      int c = accept(srv, nullptr, nullptr);
      if (c < 0) return;
      char buf[4096];
      (void)!read(c, buf, sizeof buf);
      std::string resp = i == 0   ? "HTTP/1.1 200 OK\r\nx-content-length: 1\r\n\r\nhello"
                         : i == 1 ? "HTTP/1.1 200 OK\r\nContent-Length: 99\r\n\r\nshort"
                                  : "HTTP/1.1 200 OK\r\n\r\n" + std::string(4 << 20, 'x');
      (void)!send(c, resp.data(), resp.size(), MSG_NOSIGNAL);
      close(c);
    }
  });
  Endpoint ep{"127.0.0.1", std::to_string(ntohs(a.sin_port)), false};
  HttpResult ok = http_request(ep, "GET", "/", "", {}, 1 << 20);
  CHECK(ok.status == 200 && bytes_str(ok.body) == "hello");  // a lookalike header is not Content-Length
  HttpResult trunc = http_request(ep, "GET", "/", "", {}, 1 << 20);
  CHECK(trunc.status == 0 && !trunc.error.empty());
  HttpResult big = http_request(ep, "GET", "/", "", {}, 1 << 20);
  CHECK(big.status == 0 && big.error == "response larger than allowed");
  t.join();
  close(srv);
}

static void test_tls(const std::string &url) {
  auto ep = parse_ws_url(url);
  CHECK(ep && ep->tls);
  std::string err;
  // Only the test CA can vouch for this server: the bundled roots must refuse it.
  set_test_ca_pem("");
  { WebSocket ws; CHECK(!ws.connect(*ep, "/ws", &err)); }
  std::ifstream f(std::getenv("SYNC_TEST_CA"));
  std::stringstream pem;
  pem << f.rdbuf();
  set_test_ca_pem(pem.str());
  { WebSocket ws; CHECK(ws.connect(*ep, "/ws", &err)); }
  // A valid chain for a different name is refused as well.
  Endpoint wrong = *ep;
  wrong.host = "127.0.0.1";
  { WebSocket ws; CHECK(!ws.connect(wrong, "/ws", &err)); }
}

int main() {
  test_crypto();
  auto root = std::filesystem::temp_directory_path() / ("sync_unit_" + random_id());
  test_handlers(root);
  std::filesystem::remove_all(root);
  test_http_cap();
  if (const char *tls_url = std::getenv("SYNC_TEST_TLS_GATEWAY")) {
    test_tls(tls_url);
    if (test_e2e(tls_url)) std::printf("TLS e2e ran against %s\n", tls_url);
    set_test_ca_pem("");
  }
  if (const char *url = std::getenv("SYNC_TEST_GATEWAY")) {
    if (test_e2e(url)) std::printf("e2e ran against %s\n", url);
  } else {
    std::printf("e2e skipped (set SYNC_TEST_GATEWAY)\n");
  }
  std::printf(failures ? "%d FAILED\n" : "all passed\n", failures);
  return failures ? 1 : 0;
}
