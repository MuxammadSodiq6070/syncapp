-- Idempotent: the gateway applies this on every start, under an advisory lock.
--
-- A separate schema keeps these tables off Supabase's public Data API, which only
-- exposes "public" by default. RLS with no policies is the second layer: if someone
-- ever exposes the schema, the anon and authenticated roles still see nothing. The
-- gateway connects as the database owner, which RLS does not restrict.
CREATE SCHEMA IF NOT EXISTS sync_gateway;

CREATE TABLE IF NOT EXISTS sync_gateway.users (
  id             text PRIMARY KEY,
  box_pk         text NOT NULL,
  box_sig        text NOT NULL,
  username       text NOT NULL DEFAULT '',
  username_lower text UNIQUE,
  display_name   text NOT NULL DEFAULT '',
  last_seen      bigint NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS users_username_prefix
  ON sync_gateway.users (username_lower text_pattern_ops);

CREATE TABLE IF NOT EXISTS sync_gateway.queue (
  seq        bigserial PRIMARY KEY,
  recipient  text NOT NULL,
  sender     text NOT NULL,
  blob       text NOT NULL,
  bytes      integer NOT NULL,
  created_at bigint NOT NULL
);
CREATE INDEX IF NOT EXISTS queue_recipient ON sync_gateway.queue (recipient, seq);
CREATE INDEX IF NOT EXISTS queue_created ON sync_gateway.queue (created_at);

-- Counters, so a send never has to add up a whole queue.
CREATE TABLE IF NOT EXISTS sync_gateway.queue_usage (
  recipient text PRIMARY KEY,
  rows      integer NOT NULL,
  bytes     bigint NOT NULL
);
CREATE TABLE IF NOT EXISTS sync_gateway.queue_share (
  recipient text NOT NULL,
  sender    text NOT NULL,
  rows      integer NOT NULL,
  bytes     bigint NOT NULL,
  PRIMARY KEY (recipient, sender)
);

CREATE TABLE IF NOT EXISTS sync_gateway.watches (
  watcher text NOT NULL,
  target  text NOT NULL,
  PRIMARY KEY (watcher, target)
);
CREATE INDEX IF NOT EXISTS watches_target ON sync_gateway.watches (target, watcher);

CREATE TABLE IF NOT EXISTS sync_gateway.media (
  id         text PRIMARY KEY,
  owner      text NOT NULL,
  bytes      bigint NOT NULL,
  created_at bigint NOT NULL
);
CREATE INDEX IF NOT EXISTS media_owner ON sync_gateway.media (owner);
CREATE INDEX IF NOT EXISTS media_created ON sync_gateway.media (created_at);

CREATE TABLE IF NOT EXISTS sync_gateway.market (
  id          text PRIMARY KEY,
  seller      text NOT NULL,
  seller_name text NOT NULL,
  title       text NOT NULL,
  price       text NOT NULL,
  description text NOT NULL,
  category    text NOT NULL,
  created_at  bigint NOT NULL
);
CREATE INDEX IF NOT EXISTS market_seller ON sync_gateway.market (seller);
CREATE INDEX IF NOT EXISTS market_created ON sync_gateway.market (created_at DESC);

ALTER TABLE sync_gateway.users       ENABLE ROW LEVEL SECURITY;
ALTER TABLE sync_gateway.queue       ENABLE ROW LEVEL SECURITY;
ALTER TABLE sync_gateway.queue_usage ENABLE ROW LEVEL SECURITY;
ALTER TABLE sync_gateway.queue_share ENABLE ROW LEVEL SECURITY;
ALTER TABLE sync_gateway.watches     ENABLE ROW LEVEL SECURITY;
ALTER TABLE sync_gateway.media       ENABLE ROW LEVEL SECURITY;
ALTER TABLE sync_gateway.market      ENABLE ROW LEVEL SECURITY;

-- Sign-up verification. The number itself is never stored: phone_hash is a keyed
-- hash, and the unique index is what makes one number mean one account.
ALTER TABLE sync_gateway.users ADD COLUMN IF NOT EXISTS phone_hash text;
CREATE UNIQUE INDEX IF NOT EXISTS users_phone_hash ON sync_gateway.users (phone_hash)
  WHERE phone_hash IS NOT NULL;

-- One-time sign-up codes. Keyed by the same hash as users.phone_hash, so no number
-- is stored here either, and the code itself is kept only as a keyed hash.
CREATE TABLE IF NOT EXISTS sync_gateway.signup_codes (
  phone_hash text PRIMARY KEY,
  code_hash  text NOT NULL,
  expires_at bigint NOT NULL,
  attempts   integer NOT NULL DEFAULT 0,
  sent_at    bigint NOT NULL,
  sent_day   date NOT NULL,
  sent_today integer NOT NULL DEFAULT 1
);
CREATE INDEX IF NOT EXISTS signup_codes_expires ON sync_gateway.signup_codes (expires_at);
ALTER TABLE sync_gateway.signup_codes ENABLE ROW LEVEL SECURITY;

-- A single counter row bounding what the whole service may spend on SMS in a day.
CREATE TABLE IF NOT EXISTS sync_gateway.sms_budget (
  day  date PRIMARY KEY,
  sent integer NOT NULL
);
ALTER TABLE sync_gateway.sms_budget ENABLE ROW LEVEL SECURITY;

-- The device this account last connected from. A change means someone signed in
-- somewhere else, which is what the service chat reports.
ALTER TABLE sync_gateway.users ADD COLUMN IF NOT EXISTS device_id text NOT NULL DEFAULT '';

-- Messages from Sync itself: sign-in notices and the like. Not end-to-end encrypted,
-- because the gateway is the author, and labelled as such in the app. Each is handed
-- to the next device that connects and then marked delivered, so a notice survives
-- the account being offline.
CREATE TABLE IF NOT EXISTS sync_gateway.service_messages (
  id         text PRIMARY KEY,
  user_id    text NOT NULL,
  kind       text NOT NULL,
  body       jsonb NOT NULL,
  created_at bigint NOT NULL,
  delivered  boolean NOT NULL DEFAULT false
);
CREATE INDEX IF NOT EXISTS service_messages_pending
  ON sync_gateway.service_messages (user_id, created_at) WHERE NOT delivered;
ALTER TABLE sync_gateway.service_messages ENABLE ROW LEVEL SECURITY;

-- Sign-up through a Telegram bot. The app opens the bot with a one-time nonce; the
-- person taps Start and shares their number, which Telegram itself vouches for. The
-- number is never stored here either: only the same keyed hash as users.phone_hash.
-- A ticket is what the app then presents to register, once and briefly.
CREATE TABLE IF NOT EXISTS sync_gateway.bot_verifications (
  nonce       text PRIMARY KEY,
  created_at  bigint NOT NULL,
  telegram_id bigint,
  phone_hash  text,
  ticket      text UNIQUE,
  consumed    boolean NOT NULL DEFAULT false
);
CREATE INDEX IF NOT EXISTS bot_verifications_chat
  ON sync_gateway.bot_verifications (telegram_id, created_at DESC) WHERE NOT consumed;
CREATE INDEX IF NOT EXISTS bot_verifications_created
  ON sync_gateway.bot_verifications (created_at);
ALTER TABLE sync_gateway.bot_verifications ENABLE ROW LEVEL SECURITY;
