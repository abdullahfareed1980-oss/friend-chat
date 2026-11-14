import { DatabaseSync } from 'node:sqlite';
import { readFileSync } from 'node:fs';
import { randomUUID } from 'node:crypto';

const SCHEMA = readFileSync(new URL('./sql/schema.sql', import.meta.url), 'utf8');

/** Columns added after the first release, applied to existing databases. */
const COLUMN_MIGRATIONS = {
  users: {
    phone: 'TEXT',
    country_code: 'TEXT',
    phone_verified_at: 'TEXT',
    email: 'TEXT',
    email_verified_at: 'TEXT',
  },
  otp_challenges: {
    email: 'TEXT',
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

/** Find direct conversation between two specific users. */
export function directConversationBetween(db, userIdA, userIdB) {
  return db
    .prepare(
      `SELECT c.* FROM conversations c
         JOIN conversation_members m1 ON m1.conversation_id = c.id
         JOIN conversation_members m2 ON m2.conversation_id = c.id
        WHERE c.kind = 'direct' AND m1.user_id = ? AND m2.user_id = ?
        LIMIT 1`,
    )
    .get(userIdA, userIdB);
}

/** Get or create a direct conversation between two users. */
export function getOrCreateDirectConversation(db, userIdA, userIdB) {
  const existing = directConversationBetween(db, userIdA, userIdB);
  if (existing) return existing;

  const conversationId = randomUUID();
  const at = nowIso();
  db.prepare('INSERT INTO conversations (id, kind, created_at) VALUES (?, ?, ?)').run(
    conversationId,
    'direct',
    at,
  );
  db.prepare('INSERT INTO conversation_members (conversation_id, user_id) VALUES (?, ?)').run(
    conversationId,
    userIdA,
  );
  db.prepare('INSERT INTO conversation_members (conversation_id, user_id) VALUES (?, ?)').run(
    conversationId,
    userIdB,
  );
  return { id: conversationId, kind: 'direct', created_at: at };
}

/** The single conversation shared by the two users (backward compatibility). */
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

/** Returns list of all conversations for this user with peer and last message snippet. */
export function listConversationsForUser(db, userId) {
  const convIds = conversationIdsFor(db, userId);
  if (convIds.length === 0) return [];

  const list = [];
  for (const cid of convIds) {
    const conv = db.prepare('SELECT * FROM conversations WHERE id = ?').get(cid);
    if (!conv) continue;
    const peer = peerOf(db, cid, userId);
    const lastMsg = db
      .prepare('SELECT * FROM messages WHERE conversation_id = ? ORDER BY seq DESC LIMIT 1')
      .get(cid);
    const unread = db
      .prepare('SELECT COUNT(*) AS n FROM messages WHERE conversation_id = ? AND sender_id <> ? AND read_at IS NULL')
      .get(cid, userId).n;

    list.push({
      conversation: { id: conv.id, kind: conv.kind, createdAt: conv.created_at },
      peer: serializeUser(peer),
      lastMessage: serializeMessage(lastMsg),
      unreadCount: Number(unread),
    });
  }
  return list;
}

/** Returns all registered users except self for contact discovery. */
export function getAllContacts(db, currentUserId) {
  const rows = db
    .prepare('SELECT * FROM users WHERE id <> ? ORDER BY display_name ASC')
    .all(currentUserId);
  return rows.map((u) => {
    const directConv = directConversationBetween(db, currentUserId, u.id);
    return {
      ...serializeUser(u),
      conversationId: directConv?.id ?? null,
    };
  });
}

/** Sync and discover contacts matching phone numbers from user's address book. */
export function getContactsByPhones(db, currentUserId, phoneNumbers = []) {
  if (!phoneNumbers || !Array.isArray(phoneNumbers) || phoneNumbers.length === 0) {
    return getAllContacts(db, currentUserId);
  }
  const cleanNumbers = [
    ...new Set(
      phoneNumbers
        .map((p) => String(p).replace(/\D/g, ''))
        .filter((p) => p.length >= 6),
    ),
  ];
  if (cleanNumbers.length === 0) {
    return [];
  }
  const placeholders = cleanNumbers.map(() => '?').join(',');
  const rows = db
    .prepare(`SELECT * FROM users WHERE id <> ? AND phone IN (${placeholders}) ORDER BY display_name ASC`)
    .all(currentUserId, ...cleanNumbers);
  return rows.map((u) => {
    const directConv = directConversationBetween(db, currentUserId, u.id);
    return {
      ...serializeUser(u),
      conversationId: directConv?.id ?? null,
    };
  });
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
    email: row.email ?? null,
    phoneVerified: Boolean(row.phone_verified_at),
    emailVerified: Boolean(row.email_verified_at),
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
