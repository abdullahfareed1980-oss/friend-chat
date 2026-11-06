import { DatabaseSync } from 'node:sqlite';
import { readFileSync } from 'node:fs';

const SCHEMA = readFileSync(new URL('./sql/schema.sql', import.meta.url), 'utf8');

/** Columns added after the first release, applied to existing databases. */
const COLUMN_MIGRATIONS = {
  users: {
    phone: 'TEXT',
    country_code: 'TEXT',
    phone_verified_at: 'TEXT',
  },
};

function ensureColumns(db) {
  for (const [table, columns] of Object.entries(COLUMN_MIGRATIONS)) {
    let existing;
    try {
      existing = new Set(
        db.prepare('SELECT name FROM pragma_table_info(?)').all(table).map((row) => row.name),
      );
    } catch {
      continue; // table does not exist yet
    }
    for (const [column, type] of Object.entries(columns)) {
      if (existing.has(column)) continue;
      db.exec(`ALTER TABLE ${table} ADD COLUMN ${column} ${type}`);
      console.log(`[friend-chat] migrated: ${table}.${column} added`);
    }
  }
}

/**
 * Open (and migrate) the Friend Chat database.
 * `node:sqlite` ships with Node, so a self-hosted install has no native
 * addon to compile - one less moving part on a Raspberry Pi.
 */
export function openDatabase(file) {
  const db = new DatabaseSync(file);
  db.exec('PRAGMA journal_mode = WAL;');
  db.exec('PRAGMA foreign_keys = ON;');
  db.exec('PRAGMA synchronous = NORMAL;');
  db.exec('PRAGMA busy_timeout = 5000;');
  db.exec(SCHEMA);
  ensureColumns(db);
  return db;
}

export function nowIso() {
  return new Date().toISOString();
}

export function audit(db, event, userId = null, detail = null) {
  try {
    db.prepare(
      'INSERT INTO audit_log (at, event, user_id, detail) VALUES (?, ?, ?, ?)',
    ).run(nowIso(), event, userId, detail ? JSON.stringify(detail) : null);
  } catch {
    /* the audit trail must never take the server down */
  }
}

/** The single conversation shared by the two users. */
export function primaryConversation(db) {
  return db
    .prepare("SELECT * FROM conversations WHERE kind = 'direct' ORDER BY created_at LIMIT 1")
    .get();
}

export function conversationIdsFor(db, userId) {
  return db
    .prepare('SELECT conversation_id FROM conversation_members WHERE user_id = ?')
    .all(userId)
    .map((row) => row.conversation_id);
}

export function isMember(db, conversationId, userId) {
  return Boolean(
    db
      .prepare('SELECT 1 AS ok FROM conversation_members WHERE conversation_id = ? AND user_id = ?')
      .get(conversationId, userId),
  );
}

/** The other person in a two-person conversation. */
export function peerOf(db, conversationId, userId) {
  return db
    .prepare(
      `SELECT u.* FROM conversation_members m
         JOIN users u ON u.id = m.user_id
        WHERE m.conversation_id = ? AND m.user_id <> ?`,
    )
    .get(conversationId, userId);
}

export function serializeUser(row) {
  if (!row) return null;
  return {
    id: row.id,
    username: row.username,
    displayName: row.display_name,
    phone: row.phone ?? null,
    countryCode: row.country_code ?? null,
    phoneVerified: Boolean(row.phone_verified_at),
    isBusiness: Boolean(row.is_business),
    businessName: row.business_name,
    accentColor: row.accent_color,
    identityKey: row.identity_key,
    createdAt: row.created_at,
    lastSeenAt: row.last_seen_at,
  };
}

export function serializeMessage(row) {
  if (!row) return null;
  return {
    seq: Number(row.seq),
    uuid: row.uuid,
    conversationId: row.conversation_id,
    senderId: row.sender_id,
    clientId: row.client_id,
    kind: row.kind,
    envelope: row.deleted_at ? null : row.envelope,
    mediaId: row.media_id,
    replyTo: row.reply_to,
    createdAt: row.created_at,
    deliveredAt: row.delivered_at,
    readAt: row.read_at,
    deletedAt: row.deleted_at,
  };
}

export function serializeMedia(row) {
  if (!row) return null;
  return {
    id: row.id,
    ownerId: row.owner_id,
    conversationId: row.conversation_id,
    sizeBytes: Number(row.size_bytes),
    sha256: row.sha256,
    createdAt: row.created_at,
  };
}
