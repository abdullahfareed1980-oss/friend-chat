-- ===========================================================================
-- Friend Chat Server - SQLite schema
--
-- Design rule that drives the whole schema: THE SERVER STORES NO PLAINTEXT.
-- A message body exists only as `envelope`: a base64 X25519 + AES-256-GCM
-- blob produced on a phone or desktop app. The server can order, queue,
-- deliver and delete messages, but it cannot read them.
--
-- `messages.seq` is the single global ordering cursor. Every client keeps the
-- highest seq it has and asks for everything newer after a reconnect, which is
-- what makes "switch from Wi-Fi to mobile data" invisible to the user.
-- ===========================================================================

PRAGMA user_version = 1;

-- --------------------------------------------------------------------------
-- People. Exactly two rows by design (MAX_USERS=2, enforced in code).
-- Sign-in is phone number + OTP, WhatsApp style; there is no public sign-up.
-- --------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS users (
  id                TEXT PRIMARY KEY,          -- uuid
  username          TEXT NOT NULL UNIQUE,      -- internal handle / fallback login
  display_name      TEXT NOT NULL,
  password_hash     TEXT,                      -- scrypt$... (Two-Step Verification password)
  phone             TEXT UNIQUE,               -- E.164 digits, no '+'
  country_code      TEXT,                      -- '+62'
  phone_verified_at TEXT,
  email             TEXT UNIQUE,               -- Gmail / primary email bound to phone
  email_verified_at TEXT,
  is_business       INTEGER NOT NULL DEFAULT 0,
  business_name     TEXT,
  accent_color      TEXT NOT NULL DEFAULT '#4F46E5',
  identity_key      TEXT,                      -- base64 X25519 public key (E2EE)
  created_at        TEXT NOT NULL,
  last_seen_at      TEXT
);

-- --------------------------------------------------------------------------
-- One-time codes. The plaintext code never touches the disk: only an
-- HMAC of (challenge id + code) is stored, and it dies in 10 minutes.
-- --------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS otp_challenges (
  id          TEXT PRIMARY KEY,
  phone       TEXT NOT NULL,
  country_code TEXT NOT NULL,
  email       TEXT,
  code_hash   TEXT NOT NULL,
  attempts    INTEGER NOT NULL DEFAULT 0,
  created_at  TEXT NOT NULL,
  expires_at  TEXT NOT NULL,
  consumed_at TEXT,
  user_id     TEXT REFERENCES users(id) ON DELETE SET NULL,
  ip          TEXT
);

CREATE INDEX IF NOT EXISTS idx_otp_phone ON otp_challenges(phone, created_at);

-- --------------------------------------------------------------------------
-- One direct conversation between the two users.
-- --------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS conversations (
  id         TEXT PRIMARY KEY,
  kind       TEXT NOT NULL DEFAULT 'direct',
  created_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS conversation_members (
  conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
  user_id         TEXT NOT NULL REFERENCES users(id)          ON DELETE CASCADE,
  PRIMARY KEY (conversation_id, user_id)
);

-- --------------------------------------------------------------------------
-- Attachments. Written before the message that references them.
-- --------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS media (
  id              TEXT PRIMARY KEY,
  owner_id        TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  conversation_id TEXT REFERENCES conversations(id)  ON DELETE SET NULL,
  size_bytes      INTEGER NOT NULL,
  sha256          TEXT NOT NULL,               -- integrity of the ciphertext
  path            TEXT NOT NULL,               -- relative file under DATA_DIR/media
  created_at      TEXT NOT NULL
);

-- --------------------------------------------------------------------------
-- Messages. `envelope` is opaque to the server.
-- --------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS messages (
  seq             INTEGER PRIMARY KEY AUTOINCREMENT,  -- global sync cursor
  uuid            TEXT NOT NULL UNIQUE,               -- client-visible id
  conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
  sender_id       TEXT NOT NULL REFERENCES users(id)         ON DELETE CASCADE,
  client_id       TEXT NOT NULL,                      -- idempotency key
  kind            TEXT NOT NULL DEFAULT 'text',       -- text|media|catalog|system
  envelope        TEXT NOT NULL,                      -- base64 ciphertext blob
  media_id        TEXT REFERENCES media(id) ON DELETE SET NULL,
  reply_to        TEXT,                               -- uuid of quoted message
  created_at      TEXT NOT NULL,
  delivered_at    TEXT,                               -- persisted on peer device
  read_at         TEXT,                               -- chat opened on peer device
  deleted_at      TEXT,                               -- tombstone, envelope nulled
  UNIQUE (sender_id, client_id)                       -- retry-safe sends
);

CREATE INDEX IF NOT EXISTS idx_messages_conv_seq ON messages(conversation_id, seq);
CREATE INDEX IF NOT EXISTS idx_messages_pending  ON messages(sender_id, read_at);

-- --------------------------------------------------------------------------
-- Business tooling. These documents are intentionally server-visible metadata
-- (catalog prices, label names, quick replies). Private conversation content
-- is never stored here - the auto-reply engine runs on the device.
-- --------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS business_docs (
  user_id    TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  section    TEXT NOT NULL,                   -- quick_replies|auto_reply|catalog|labels
  payload    TEXT NOT NULL DEFAULT '{}',      -- JSON
  rev        INTEGER NOT NULL DEFAULT 1,      -- last-write-wins counter
  updated_at TEXT NOT NULL,
  PRIMARY KEY (user_id, section)
);

-- --------------------------------------------------------------------------
-- Devices, for multi-device fan-out (phone + Windows PC) and "last seen".
-- --------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS devices (
  id           TEXT PRIMARY KEY,
  user_id      TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  name         TEXT,
  platform     TEXT,
  created_at   TEXT NOT NULL,
  last_seen_at TEXT
);

-- --------------------------------------------------------------------------
-- Local-only audit trail. Nothing here is ever sent to a third party; it is
-- your own record of logins, OTP requests and key changes on your own box.
-- --------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS audit_log (
  id      INTEGER PRIMARY KEY AUTOINCREMENT,
  at      TEXT NOT NULL,
  event   TEXT NOT NULL,
  user_id TEXT,
  detail  TEXT
);
