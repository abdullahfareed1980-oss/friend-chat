import { randomUUID } from 'node:crypto';
import { verifyToken } from './auth.js';
import { nowIso, peerOf, serializeMessage, serializeUser } from './db.js';

const KINDS = new Set(['text', 'media', 'catalog', 'system']);
const userRoom = (id) => `user:${id}`;

/**
 * Attach the Socket.io layer.
 *
 * Event contract (see docs/API.md for the full table):
 *   client -> server : message:send | receipt:delivered | receipt:read |
 *                      typing | sync:request | message:delete | presence:ping
 *   server -> client : server:hello | message:new | message:deleted |
 *                      receipt:update | typing | sync:result | presence |
 *                      peer:identity | business:update
 */
export function attachRealtime(io, ctx) {
  const { db, config, log } = ctx;

  const q = {
    userById: db.prepare('SELECT * FROM users WHERE id = ?'),
    conversation: db.prepare("SELECT * FROM conversations WHERE kind = 'direct' LIMIT 1"),
    isMember: db.prepare('SELECT 1 AS ok FROM conversation_members WHERE conversation_id = ? AND user_id = ?'),
    byClientId: db.prepare('SELECT * FROM messages WHERE sender_id = ? AND client_id = ?'),
    bySeq: db.prepare('SELECT * FROM messages WHERE seq = ?'),
    insert: db.prepare(
      `INSERT INTO messages (uuid, conversation_id, sender_id, client_id, kind, envelope, media_id, reply_to, created_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
    ),
    touchDelivered: db.prepare(
      `UPDATE messages SET delivered_at = ?
        WHERE seq = ? AND sender_id <> ? AND delivered_at IS NULL`,
    ),
    touchRead: db.prepare(
      `UPDATE messages SET read_at = ?, delivered_at = COALESCE(delivered_at, ?)
        WHERE conversation_id = ? AND sender_id <> ? AND seq <= ? AND read_at IS NULL`,
    ),
    tombstone: db.prepare(
      `UPDATE messages SET deleted_at = ?, envelope = ''
        WHERE uuid = ? AND sender_id = ? AND deleted_at IS NULL`,
    ),
    setLastSeen: db.prepare('UPDATE users SET last_seen_at = ? WHERE id = ?'),
    device: db.prepare(
      `INSERT INTO devices (id, user_id, name, platform, created_at, last_seen_at)
         VALUES (?, ?, ?, ?, ?, ?)
       ON CONFLICT(id) DO UPDATE SET last_seen_at = excluded.last_seen_at`,
    ),
  };

  /* ------------------------------------------------------------------ */
  /* Handshake auth                                                      */
  /* ------------------------------------------------------------------ */
  io.use((socket, next) => {
    const token =
      socket.handshake.auth?.token ??
      (socket.handshake.headers?.authorization ?? '').replace(/^Bearer /i, '').trim();
    const claims = token ? verifyToken(token, config.jwtSecret) : null;
    if (!claims) return next(new Error('unauthorized'));

    const user = q.userById.get(claims.sub);
    if (!user) return next(new Error('unauthorized'));

    socket.data.user = user;
    next();
  });

  /** userId -> Set<socketId> */
  const connections = new Map();

  const peerIdIn = (conversationId, userId) => peerOf(db, conversationId, userId)?.id ?? null;

  const isOnline = (userId) => (connections.get(userId)?.size ?? 0) > 0;

  io.on('connection', (socket) => {
    const user = socket.data.user;
    const conversation = q.conversation.get();
    const set = connections.get(user.id) ?? new Set();
    set.add(socket.id);
    connections.set(user.id, set);

    socket.join(userRoom(user.id));
    if (conversation) socket.join(`conv:${conversation.id}`);

    const peer = conversation ? peerOf(db, conversation.id, user.id) : null;

    log(config, `[socket] ${user.username} connected (${socket.id})`);

    if (set.size === 1) {
      io.to(peer ? userRoom(peer.id) : 'nobody').emit('presence', {
        userId: user.id,
        online: true,
        at: nowIso(),
      });
    }

    const hello = {
      service: config.serviceName,
      version: config.version,
      user: serializeUser(user),
      peer: serializeUser(peer),
      conversation: conversation ? { id: conversation.id, kind: conversation.kind } : null,
      peerOnline: peer ? isOnline(peer.id) : false,
      serverTime: nowIso(),
    };
    socket.emit('server:hello', hello);

    const device = socket.handshake.auth?.device;
    if (device?.id) {
      const at = nowIso();
      q.device.run(String(device.id), user.id, device.name ?? null, device.platform ?? null, at, at);
    }

    /* ---------------------------------------------------------------- */
    /* Sending                                                           */
    /* ---------------------------------------------------------------- */
    socket.on('message:send', (payload = {}, ack = () => {}) => {
      try {
        const conversationId = payload.conversationId ?? conversation?.id;
        const clientId = String(payload.clientId ?? '');
        const kind = String(payload.kind ?? 'text');
        const envelope = payload.envelope;

        if (!conversationId) throw new Error('missing_conversation');
        if (!clientId || clientId.length > 80) throw new Error('invalid_client_id');
        if (!KINDS.has(kind)) throw new Error('invalid_kind');
        if (typeof envelope !== 'string' || envelope.length === 0) throw new Error('missing_envelope');
        if (envelope.length > config.maxEnvelopeChars) throw new Error('envelope_too_large');
        if (!q.isMember.get(conversationId, user.id)) throw new Error('forbidden');

        // Idempotent: the phone retries after a network switch without dupes.
        const existing = q.byClientId.get(user.id, clientId);
        if (existing) {
          return ack({ ok: true, duplicate: true, message: serializeMessage(existing) });
        }

        const uuid = randomUUID();
        const createdAt = nowIso();
        const info = q.insert.run(
          uuid,
          conversationId,
          user.id,
          clientId,
          kind,
          envelope,
          payload.mediaId ?? null,
          payload.replyTo ?? null,
          createdAt,
        );

        const row = q.bySeq.get(Number(info.lastInsertRowid));
        const message = serializeMessage(row);
        const peerId = peerIdIn(conversationId, user.id);

        if (peerId) io.to(userRoom(peerId)).emit('message:new', message);
        // The sender's other devices (tablet, second phone) stay in sync,
        // but the sending socket already has it optimistically.
        socket.to(userRoom(user.id)).emit('message:new', message);

        ack({ ok: true, message });
      } catch (err) {
        ack({ ok: false, error: err.message });
      }
    });

    /* ---------------------------------------------------------------- */
    /* Delivery + read receipts                                          */
    /* ---------------------------------------------------------------- */
    socket.on('receipt:delivered', ({ seqs } = {}, ack = () => {}) => {
      try {
        const list = Array.isArray(seqs) ? seqs.slice(0, 200) : [];
        const at = nowIso();
        let highest = 0;
        for (const seq of list) {
          const n = Number(seq);
          if (!Number.isInteger(n) || n <= 0) continue;
          const info = q.touchDelivered.run(at, n, user.id);
          if (info.changes > 0 && n > highest) highest = n;
        }
        if (highest > 0) {
          const conv = conversation?.id;
          const peerId = conv ? peerIdIn(conv, user.id) : null;
          if (peerId) {
            io.to(userRoom(peerId)).emit('receipt:update', {
              conversationId: conv,
              upToSeq: highest,
              status: 'delivered',
              at,
              by: user.id,
            });
          }
        }
        ack({ ok: true });
      } catch (err) {
        ack({ ok: false, error: err.message });
      }
    });

    socket.on('receipt:read', (payload = {}, ack = () => {}) => {
      try {
        const convId = payload.conversationId ?? conversation?.id;
        const upToSeq = Number(payload.upToSeq ?? 0) || 0;
        if (!convId || !q.isMember.get(convId, user.id)) throw new Error('forbidden');
        if (upToSeq > 0) {
          const at = nowIso();
          q.touchRead.run(at, at, convId, user.id, upToSeq);
          const peerId = peerIdIn(convId, user.id);
          if (peerId) {
            io.to(userRoom(peerId)).emit('receipt:update', {
              conversationId: convId,
              upToSeq,
              status: 'read',
              at,
              by: user.id,
            });
          }
        }
        ack({ ok: true });
      } catch (err) {
        ack({ ok: false, error: err.message });
      }
    });

    /* ---------------------------------------------------------------- */
    /* Typing, presence, sync, delete                                     */
    /* ---------------------------------------------------------------- */
    socket.on('typing', ({ isTyping = false } = {}) => {
      if (!conversation) return;
      const peerId = peerIdIn(conversation.id, user.id);
      if (!peerId) return;
      io.to(userRoom(peerId)).emit('typing', {
        conversationId: conversation.id,
        userId: user.id,
        isTyping: Boolean(isTyping),
        at: nowIso(),
      });
    });

    socket.on('presence:ping', (_, ack = () => {}) => {
      const at = nowIso();
      q.setLastSeen.run(at, user.id);
      ack({ ok: true, at });
    });

    socket.on('sync:request', ({ sinceSeq = 0, limit = 300 } = {}, ack = () => {}) => {
      try {
        const since = Math.max(0, Number(sinceSeq) || 0);
        const take = Math.min(500, Math.max(1, Number(limit) || 300));
        const convId = conversation?.id;
        if (!convId) return ack({ ok: true, messages: [], latestSeq: since, hasMore: false });

        const rows = db
          .prepare('SELECT * FROM messages WHERE conversation_id = ? AND seq > ? ORDER BY seq ASC LIMIT ?')
          .all(convId, since, take + 1);
        const hasMore = rows.length > take;
        const page = hasMore ? rows.slice(0, take) : rows;
        ack({
          ok: true,
          messages: page.map(serializeMessage),
          latestSeq: Number(db.prepare('SELECT COALESCE(MAX(seq),0) AS s FROM messages WHERE conversation_id = ?').get(convId).s),
          hasMore,
          serverTime: nowIso(),
        });
      } catch (err) {
        ack({ ok: false, error: err.message });
      }
    });

    socket.on('message:delete', ({ uuid } = {}, ack = () => {}) => {
      try {
        const at = nowIso();
        const info = q.tombstone.run(at, String(uuid), user.id);
        if (info.changes > 0 && conversation) {
          const event = { uuid, conversationId: conversation.id, at };
          const peerId = peerIdIn(conversation.id, user.id);
          if (peerId) io.to(userRoom(peerId)).emit('message:deleted', event);
          socket.to(userRoom(user.id)).emit('message:deleted', event);
        }
        ack({ ok: info.changes > 0 });
      } catch (err) {
        ack({ ok: false, error: err.message });
      }
    });

    /* ---------------------------------------------------------------- */
    /* Disconnect                                                        */
    /* ---------------------------------------------------------------- */
    socket.on('disconnect', (reason) => {
      const sockets = connections.get(user.id);
      sockets?.delete(socket.id);
      if (sockets && sockets.size === 0) {
        connections.delete(user.id);
        const at = nowIso();
        q.setLastSeen.run(at, user.id);
        if (peer) io.to(userRoom(peer.id)).emit('presence', { userId: user.id, online: false, at });
      }
      log(config, `[socket] ${user.username} disconnected (${reason})`);
    });
  });
}
