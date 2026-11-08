#include "db.h"

#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

#include "sqlite3.h"

namespace sync_core {

static void check(sqlite3 *db, int rc, const char *what) {
  if (rc != SQLITE_OK && rc != SQLITE_ROW && rc != SQLITE_DONE)
    throw std::runtime_error(std::string(what) + ": " + sqlite3_errmsg(db));
}

Stmt::Stmt(sqlite3 *db, const char *sql) : db_(db) {
  check(db, sqlite3_prepare_v2(db, sql, -1, &s_, nullptr), sql);
}
Stmt::~Stmt() { sqlite3_finalize(s_); }

Stmt &Stmt::bind(int i, const std::string &v) {
  check(db_, sqlite3_bind_text(s_, i, v.data(), int(v.size()), SQLITE_TRANSIENT), "bind");
  return *this;
}
Stmt &Stmt::bind(int i, int64_t v) {
  check(db_, sqlite3_bind_int64(s_, i, v), "bind");
  return *this;
}
Stmt &Stmt::bind(int i, const std::vector<uint8_t> &v) {
  // A zero-length blob still needs a non-null pointer to stay distinct from NULL.
  static const uint8_t empty = 0;
  check(db_, sqlite3_bind_blob(s_, i, v.empty() ? &empty : v.data(), int(v.size()), SQLITE_TRANSIENT),
        "bind");
  return *this;
}
Stmt &Stmt::bind_null(int i) {
  check(db_, sqlite3_bind_null(s_, i), "bind");
  return *this;
}

bool Stmt::step() {
  int rc = sqlite3_step(s_);
  check(db_, rc, "step");
  return rc == SQLITE_ROW;
}
void Stmt::reset() {
  sqlite3_reset(s_);
  sqlite3_clear_bindings(s_);
}
bool Stmt::is_null(int c) { return sqlite3_column_type(s_, c) == SQLITE_NULL; }
std::string Stmt::text(int c) {
  auto p = sqlite3_column_text(s_, c);
  return p ? std::string(reinterpret_cast<const char *>(p), size_t(sqlite3_column_bytes(s_, c)))
           : std::string();
}
int64_t Stmt::i64(int c) { return sqlite3_column_int64(s_, c); }
std::vector<uint8_t> Stmt::blob(int c) {
  auto p = static_cast<const uint8_t *>(sqlite3_column_blob(s_, c));
  int n = sqlite3_column_bytes(s_, c);
  return p ? std::vector<uint8_t>(p, p + n) : std::vector<uint8_t>();
}

static const char *kSchema = R"SQL(
PRAGMA journal_mode=WAL;
PRAGMA synchronous=NORMAL;
PRAGMA foreign_keys=ON;
CREATE TABLE IF NOT EXISTS meta(k TEXT PRIMARY KEY, v BLOB);
CREATE TABLE IF NOT EXISTS users(
  id TEXT PRIMARY KEY, box_pk TEXT, username TEXT NOT NULL DEFAULT '',
  display_name TEXT NOT NULL DEFAULT '', blocked INTEGER NOT NULL DEFAULT 0);
CREATE TABLE IF NOT EXISTS chats(
  id TEXT PRIMARY KEY, type TEXT NOT NULL, title TEXT NOT NULL DEFAULT '', admin TEXT NOT NULL DEFAULT '',
  state TEXT NOT NULL DEFAULT 'active', archived INTEGER NOT NULL DEFAULT 0,
  muted INTEGER NOT NULL DEFAULT 0, unread INTEGER NOT NULL DEFAULT 0,
  last_message TEXT, updated_at INTEGER NOT NULL DEFAULT 0, version INTEGER NOT NULL DEFAULT 0);
CREATE TABLE IF NOT EXISTS members(chat_id TEXT NOT NULL, user_id TEXT NOT NULL,
  PRIMARY KEY(chat_id, user_id));
CREATE TABLE IF NOT EXISTS messages(
  id TEXT PRIMARY KEY, chat_id TEXT NOT NULL, sender TEXT NOT NULL, kind TEXT NOT NULL,
  body BLOB NOT NULL, status TEXT NOT NULL, ts INTEGER NOT NULL, reply_to TEXT,
  edited INTEGER NOT NULL DEFAULT 0, deleted INTEGER NOT NULL DEFAULT 0);
CREATE INDEX IF NOT EXISTS messages_chat ON messages(chat_id, ts);
CREATE TABLE IF NOT EXISTS reactions(message_id TEXT NOT NULL, user_id TEXT NOT NULL, emoji TEXT NOT NULL,
  PRIMARY KEY(message_id, user_id));
CREATE TABLE IF NOT EXISTS votes(message_id TEXT NOT NULL, user_id TEXT NOT NULL, option INTEGER NOT NULL,
  PRIMARY KEY(message_id, user_id));
CREATE TABLE IF NOT EXISTS outbox(
  seq INTEGER PRIMARY KEY AUTOINCREMENT, recipient TEXT NOT NULL, mid TEXT, payload BLOB NOT NULL);
CREATE TABLE IF NOT EXISTS seen_envelopes(
  sender TEXT NOT NULL, eid TEXT NOT NULL, ts INTEGER NOT NULL, PRIMARY KEY(sender, eid)) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS stories(
  id TEXT PRIMARY KEY, sender TEXT NOT NULL, body BLOB NOT NULL, ts INTEGER NOT NULL,
  seen INTEGER NOT NULL DEFAULT 0);
)SQL";

Db::Db(const std::string &path) {
  // Private from the start: SQLite gives its -wal and -shm files this same mode.
  int pre = ::open(path.c_str(), O_CREAT | O_RDWR | O_CLOEXEC, 0600);
  if (pre >= 0) ::close(pre);
  chmod(path.c_str(), 0600);
  int rc = sqlite3_open(path.c_str(), &db_);
  if (rc != SQLITE_OK) {
    std::string e = sqlite3_errmsg(db_);
    sqlite3_close(db_);
    db_ = nullptr;
    throw std::runtime_error("open database: " + e);
  }
  sqlite3_busy_timeout(db_, 5000);
  exec(kSchema);
  add_column("chats", "creator", "TEXT NOT NULL DEFAULT ''");
  add_column("chats", "salt", "TEXT NOT NULL DEFAULT ''");
  add_column("messages", "edit_ts", "INTEGER NOT NULL DEFAULT 0");
}

void Db::add_column(const char *table, const char *column, const char *decl) {
  Stmt s(db_, "SELECT 1 FROM pragma_table_info(?) WHERE name=?");
  s.bind(1, std::string(table)).bind(2, std::string(column));
  if (s.step()) return;
  exec((std::string("ALTER TABLE ") + table + " ADD COLUMN " + column + " " + decl).c_str());
}
Db::~Db() { sqlite3_close(db_); }

void Db::exec(const char *sql) {
  char *e = nullptr;
  int rc = sqlite3_exec(db_, sql, nullptr, nullptr, &e);
  if (rc != SQLITE_OK) {
    std::string m = e ? e : "sqlite error";
    sqlite3_free(e);
    throw std::runtime_error(m);
  }
}
int64_t Db::changes() { return sqlite3_changes(db_); }

}  // namespace sync_core
