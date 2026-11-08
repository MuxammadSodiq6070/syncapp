// Thin RAII wrapper over SQLite plus the sync_core schema.
#pragma once
#include <cstdint>
#include <stdexcept>
#include <string>
#include <vector>

struct sqlite3;
struct sqlite3_stmt;

namespace sync_core {

class Stmt {
 public:
  Stmt(sqlite3 *db, const char *sql);
  ~Stmt();
  Stmt(const Stmt &) = delete;
  Stmt &operator=(const Stmt &) = delete;

  Stmt &bind(int i, const std::string &v);
  Stmt &bind(int i, int64_t v);
  Stmt &bind(int i, const std::vector<uint8_t> &v);
  Stmt &bind_null(int i);

  bool step();  // true when a row is available
  void run() { step(); }
  void reset();

  bool is_null(int c);
  std::string text(int c);
  int64_t i64(int c);
  std::vector<uint8_t> blob(int c);

 private:
  sqlite3 *db_;
  sqlite3_stmt *s_ = nullptr;
};

class Db {
 public:
  explicit Db(const std::string &path);
  ~Db();
  void exec(const char *sql);
  Stmt prepare(const char *sql) { return Stmt(db_, sql); }
  int64_t changes();
  void add_column(const char *table, const char *column, const char *decl);

 private:
  sqlite3 *db_ = nullptr;
};

class Tx {
 public:
  explicit Tx(Db &db) : db_(db) { db_.exec("BEGIN IMMEDIATE"); }
  ~Tx() {
    if (!done_) {
      try {
        db_.exec("ROLLBACK");
      } catch (...) {
      }
    }
  }
  void commit() {
    db_.exec("COMMIT");
    done_ = true;
  }

 private:
  Db &db_;
  bool done_ = false;
};

}  // namespace sync_core
