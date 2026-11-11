import express from 'express';
import {
  createHash,
  createHmac,
  randomInt,
  randomUUID,
  timingSafeEqual,
} from 'node:crypto';
import { createWriteStream, existsSync, unlinkSync } from 'node:fs';
import path from 'node:path';

import {
  audit,
  conversationIdsFor,
  directConversationBetween,
  getAllContacts,
  getOrCreateDirectConversation,
  isMember,
  listConversationsForUser,
  nowIso,
  peerOf,
  primaryConversation,
  serializeMedia,
  serializeMessage,
  serializeUser,
} from './db.js';
import { hashPassword, loginThrottle, makeRequireAuth, passwordIsWeak, signToken, verifyPassword } from './auth.js';
import { maskPhone, normalizePhone, PhoneError } from './phone.js';
import { createMailer } from './mailer.js';

const BUSINESS_SECTIONS = new Set(['quick_replies', 'auto_reply', 'catalog', 'labels']);
const DEFAULT_BUSINESS = {
  quick_replies: { items: [] },
  auto_reply: { greeting: { enabled: false, text: '' }, away: { enabled: false, text: '', schedule: null } },
  catalog: { items: [] },
  labels: { items: [] },
};

/** Opened up after sign-in: the token plus everything the app needs to boot. */
function sessionPayload(db, user) {
  const convs = listConversationsForUser(db, user.id);
  const primary = convs.length > 0 ? convs[0].conversation : primaryConversation(db);
  const peer = primary ? peerOf(db, primary.id, user.id) : null;
  const contacts = getAllContacts(db, user.id);

  return {
    user: serializeUser(user),
    conversation: primary ? { id: primary.id, kind: primary.kind, createdAt: primary.created_at } : null,
    peer: serializeUser(peer),
    conversations: convs,
    contacts,
  };
}

/** A 6-digit code is only 20 bits; bind the hash to the challenge id. */
function hashCode(config, challengeId, code) {
  return createHmac('sha256', config.jwtSecret)
    .update(`friend-chat-otp:${challengeId}:${code}`)
    .digest('hex');
}

function safeEqualHex(a, b) {
  const left = Buffer.from(String(a), 'hex');
  const right = Buffer.from(String(b), 'hex');
  return left.length === right.length && left.length > 0 && timingSafeEqual(left, right);
}

function printOtpToServerConsole(config, { phone, countryCode, code, expiresInSeconds }) {
  const display = `${countryCode} ${phone.slice(countryCode.replace(/\D/g, '').length)}`;
  const line = '─'.repeat(46);
  console.log('');
  console.log(`  ┌${line}┐`);
  console.log('  │  Friend Chat verification code             │');
  console.log(`  │                                            │`);
  console.log(`  │      ${code.split('').join(' ')}                           │`);
  console.log(`  │                                            │`);
  console.log(`  │  for ${display.padEnd(36)}│`);
  console.log(`  │  valid for ${String(Math.round(expiresInSeconds / 60)).padEnd(2)} minutes, single use       │`);
  console.log(`  └${line}┘`);
  console.log('');
  void config;
}

function noteDevice(db, userId, device, at) {
  if (!device?.id) return;
  db.prepare(
    `INSERT INTO devices (id, user_id, name, platform, created_at, last_seen_at)
       VALUES (?, ?, ?, ?, ?, ?)
     ON CONFLICT(id) DO UPDATE SET last_seen_at = excluded.last_seen_at, name = excluded.name`,
  ).run(String(device.id), userId, device.name ?? null, device.platform ?? null, at, at);
}

function issueSession({ db, config }, user, device) {
  const token = signToken(
    { sub: user.id, usr: user.username },
    config.jwtSecret,
    config.tokenTtlSeconds,
  );
  const at = nowIso();
  db.prepare('UPDATE users SET last_seen_at = ? WHERE id = ?').run(at, user.id);
  noteDevice(db, user.id, device, at);
  return { token, expiresIn: config.tokenTtlSeconds, ...sessionPayload(db, user) };
}

export function registerRoutes(app, ctx) {
  const { db, config, io } = ctx;
  const requireAuth = makeRequireAuth(db, config);
  const mailer = createMailer(config);

  /* ---------------------------------------------------------------------- */
  /* Health - also used by the app to race LAN vs public endpoints           */
  /* ---------------------------------------------------------------------- */
  app.get('/api/health', (req, res) => {
    const users = db.prepare('SELECT COUNT(*) AS n FROM users').get().n;
    res.json({
      ok: true,
      service: config.serviceName,
      version: config.version,
      time: nowIso(),
      users: Number(users),
      maxUsers: config.maxUsers,
      registrationOpen: config.allowRegistration,
      otpDelivery: mailer.isConfigured ? 'smtp' : config.otp.delivery,
      smtpConfigured: mailer.isConfigured,
      e2ee: true,
    });
  });

  /* ---------------------------------------------------------------------- */
  /* WhatsApp-style onboarding: phone + Gmail -> Email OTP -> 2-Step Password */
  /* ---------------------------------------------------------------------- */

  /**
   * Step 1: Request OTP.
   * Auto-registration enabled (no manual seeding required).
   * Sends 6-digit OTP code directly to Gmail using Nodemailer.
   * STRICT ACCOUNT LOCKING: If phone already registered, email must match!
   */
  app.post('/api/auth/request-otp', loginThrottle({ max: 20 }), express.json({ limit: '8kb' }), async (req, res) => {
    let normalized;
    try {
      normalized = normalizePhone(req.body?.countryCode, req.body?.phone);
    } catch (err) {
      if (err instanceof PhoneError) return res.status(400).json({ error: err.code });
      throw err;
    }

    let email = String(req.body?.email ?? '').trim().toLowerCase();
    const existing = db.prepare('SELECT * FROM users WHERE phone = ?').get(normalized.phone);

    // If phone not recognized and registration is restricted, reject immediately
    if (!existing) {
      const count = Number(db.prepare('SELECT COUNT(*) AS n FROM users').get().n);
      if (!config.allowRegistration || count >= config.maxUsers) {
        return res.status(403).json({
          error: 'phone_not_enrolled',
          message: 'Server registration is closed or phone is not enrolled.',
        });
      }
    }

    // If an existing registered user requests OTP and email is omitted, use bound email
    if (!email && existing?.email) {
      email = existing.email.toLowerCase();
    }

    if (!email || !email.includes('@')) {
      return res.status(400).json({
        error: 'invalid_email',
        message: 'A valid Gmail or email address is required for 2-Step Verification.',
      });
    }

    // STRICT ACCOUNT LOCKING:
    // If an already registered phone number is entered by anyone else, it must verify the exact paired Gmail.
    // If incorrect or mismatched, reject it instantly with a 403 Forbidden error ("Account locked to another email").
    if (existing && existing.email) {
      if (existing.email.toLowerCase() !== email) {
        audit(db, 'account_lock_violation', existing.id, {
          phone: maskPhone(normalized.phone),
          providedEmail: email,
          actualEmail: existing.email,
          ip: req.ip,
        });
        return res.status(403).json({
          error: 'account_locked',
          message: 'Account locked to another email',
          hint: 'This phone number is permanently paired with a different email address.',
        });
      }
    }

    // Ensure email is not already bound to a different phone
    const existingEmail = db.prepare('SELECT * FROM users WHERE lower(email) = ?').get(email);
    if (existingEmail && existingEmail.phone && existingEmail.phone !== normalized.phone) {
      return res.status(403).json({
        error: 'email_already_bound',
        message: 'This email is already locked to another phone number.',
      });
    }

    const now = Date.now();
    const recent = db
      .prepare('SELECT * FROM otp_challenges WHERE phone = ? ORDER BY created_at DESC LIMIT 1')
      .get(normalized.phone);
    if (recent && !recent.consumed_at) {
      const ageMs = now - Date.parse(recent.created_at);
      const cooldown = config.otp.resendSeconds * 1000;
      if (ageMs < cooldown) {
        return res.status(429).json({
          error: 'resend_too_soon',
          retryAfter: Math.ceil((cooldown - ageMs) / 1000),
        });
      }
    }

    const lastHour = db
      .prepare('SELECT COUNT(*) AS n FROM otp_challenges WHERE phone = ? AND created_at > ?')
      .get(normalized.phone, new Date(now - 3_600_000).toISOString()).n;
    if (Number(lastHour) >= config.otp.maxPerHour) {
      return res.status(429).json({ error: 'too_many_requests' });
    }

    const id = randomUUID();
    const code = String(randomInt(0, 1_000_000)).padStart(6, '0');
    const createdAt = new Date(now).toISOString();
    const expiresAt = new Date(now + config.otp.ttlSeconds * 1000).toISOString();

    db.prepare(
      `INSERT INTO otp_challenges (id, phone, country_code, email, code_hash, attempts, created_at, expires_at, user_id, ip)
         VALUES (?, ?, ?, ?, ?, 0, ?, ?, ?, ?)`,
    ).run(
      id,
      normalized.phone,
      normalized.countryCode,
      email,
      hashCode(config, id, code),
      createdAt,
      expiresAt,
      existing?.id ?? null,
      req.ip ?? null,
    );

    // Send code to user's Gmail via Nodemailer
    await mailer.sendOtp({
      toEmail: email,
      code,
      phone: `${normalized.countryCode} ${normalized.nationalNumber}`,
      expiresInMinutes: Math.round(config.otp.ttlSeconds / 60),
    });

    printOtpToServerConsole(config, {
      phone: normalized.phone,
      countryCode: normalized.countryCode,
      code,
      expiresInSeconds: config.otp.ttlSeconds,
    });
    audit(db, 'otp_requested', existing?.id ?? null, {
      phone: maskPhone(normalized.phone),
      email,
      ip: req.ip,
    });

    res.json({
      challengeId: id,
      phone: normalized.phone,
      countryCode: normalized.countryCode,
      email,
      expiresInSeconds: config.otp.ttlSeconds,
      resendAfterSeconds: config.otp.resendSeconds,
      delivery: mailer.isConfigured ? 'email' : config.otp.delivery,
      known: Boolean(existing),
      hasPassword: Boolean(existing?.password_hash),
      // Development-only convenience, disabled unless OTP_DEBUG=true.
      ...(config.otp.debug ? { devCode: code } : {}),
    });
  });

  /**
   * Step 2: Verify OTP.
   * If user is already registered with password, verifies password or flags requiresPassword.
   * If new user, creates account with password or flags needsPassword.
   */
  app.post('/api/auth/verify-otp', express.json({ limit: '8kb' }), (req, res) => {
    const challengeId = String(req.body?.challengeId ?? '');
    const code = String(req.body?.code ?? '').replace(/\D/g, '');
    const password = req.body?.password ? String(req.body.password) : null;
    const displayName = String(req.body?.displayName ?? '').trim();

    const challenge = db.prepare('SELECT * FROM otp_challenges WHERE id = ?').get(challengeId);
    if (!challenge) return res.status(404).json({ error: 'challenge_not_found' });
    if (challenge.consumed_at) return res.status(409).json({ error: 'challenge_used' });
    if (Date.parse(challenge.expires_at) < Date.now()) {
      return res.status(410).json({ error: 'code_expired' });
    }
    if (Number(challenge.attempts) >= config.otp.maxAttempts) {
      return res.status(429).json({ error: 'too_many_attempts' });
    }

    if (code.length !== 6 || !safeEqualHex(hashCode(config, challenge.id, code), challenge.code_hash)) {
      db.prepare('UPDATE otp_challenges SET attempts = attempts + 1 WHERE id = ?').run(challenge.id);
      audit(db, 'otp_failed', challenge.user_id, { phone: maskPhone(challenge.phone) });
      return res.status(401).json({
        error: 'invalid_code',
        attemptsRemaining: Math.max(0, config.otp.maxAttempts - Number(challenge.attempts) - 1),
      });
    }

    let user = db.prepare('SELECT * FROM users WHERE phone = ?').get(challenge.phone);

    // Existing registered user
    if (user) {
      if (password && user.password_hash) {
        if (!verifyPassword(password, user.password_hash)) {
          audit(db, 'login_failed_2step', user.id, { ip: req.ip });
          return res.status(401).json({
            error: 'invalid_password',
            message: 'Incorrect Two-Step Verification password.',
          });
        }
      } else if (password && !user.password_hash) {
        if (passwordIsWeak(password)) {
          return res.status(400).json({
            error: 'weak_password',
            message: 'Password must be at least 6 characters.',
          });
        }
        db.prepare('UPDATE users SET password_hash = ? WHERE id = ?').run(
          hashPassword(password),
          user.id,
        );
      }

      // Permanently bind email if missing
      if (!user.email && challenge.email) {
        db.prepare('UPDATE users SET email = ?, email_verified_at = ? WHERE id = ?').run(
          challenge.email,
          nowIso(),
          user.id,
        );
      }
    } else {
      // New user auto-registration
      if (!password) {
        return res.json({
          verifiedOtp: true,
          needsPassword: true,
          challengeId: challenge.id,
          phone: challenge.phone,
          email: challenge.email,
        });
      }

      if (passwordIsWeak(password)) {
        return res.status(400).json({
          error: 'weak_password',
          message: 'Password must be at least 6 characters.',
        });
      }

      const id = randomUUID();
      const name = displayName || `User ${challenge.phone.slice(-4)}`;
      const at = nowIso();

      db.prepare(
        `INSERT INTO users (id, username, display_name, password_hash, phone, country_code, phone_verified_at, email, email_verified_at, is_business, accent_color, created_at)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?, ?)`,
      ).run(
        id,
        `user_${challenge.phone.slice(-6)}_${randomInt(100, 999)}`,
        name,
        hashPassword(password),
        challenge.phone,
        challenge.country_code,
        at,
        challenge.email,
        at,
        '#00A884',
        at,
      );

      user = db.prepare('SELECT * FROM users WHERE id = ?').get(id);
      audit(db, 'account_enrolled', id, { phone: maskPhone(challenge.phone), email: challenge.email });
    }

    const at = nowIso();
    db.prepare('UPDATE otp_challenges SET consumed_at = ?, user_id = ? WHERE id = ?').run(
      at,
      user.id,
      challenge.id,
    );
    db.prepare('UPDATE users SET phone_verified_at = ?, last_seen_at = ? WHERE id = ?').run(
      at,
      at,
      user.id,
    );
    audit(db, 'otp_verified', user.id, { phone: maskPhone(challenge.phone) });

    res.json(issueSession(ctx, user, req.body?.device));
  });

  /**
   * Step 2b: Set Account Password (Two-Step Verification setup).
   * Prompts user to set password right after OTP verification.
   * Permanently binds phone number to Gmail and password hash.
   */
  app.post('/api/auth/set-password', express.json({ limit: '8kb' }), (req, res) => {
    const challengeId = String(req.body?.challengeId ?? '');
    const password = String(req.body?.password ?? '');
    const displayName = String(req.body?.displayName ?? '').trim();

    if (passwordIsWeak(password)) {
      return res.status(400).json({
        error: 'weak_password',
        message: 'Password must be at least 6 characters.',
      });
    }

    const challenge = db.prepare('SELECT * FROM otp_challenges WHERE id = ?').get(challengeId);
    if (!challenge) return res.status(404).json({ error: 'challenge_not_found' });
    if (Date.parse(challenge.expires_at) < Date.now()) {
      return res.status(410).json({ error: 'code_expired' });
    }

    let user = db.prepare('SELECT * FROM users WHERE phone = ?').get(challenge.phone);
    const at = nowIso();

    if (!user) {
      const id = randomUUID();
      const name = displayName || `User ${challenge.phone.slice(-4)}`;
      db.prepare(
        `INSERT INTO users (id, username, display_name, password_hash, phone, country_code, phone_verified_at, email, email_verified_at, is_business, accent_color, created_at)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?, ?)`,
      ).run(
        id,
        `user_${challenge.phone.slice(-6)}_${randomInt(100, 999)}`,
        name,
        hashPassword(password),
        challenge.phone,
        challenge.country_code,
        at,
        challenge.email,
        at,
        '#00A884',
        at,
      );
      user = db.prepare('SELECT * FROM users WHERE id = ?').get(id);
      audit(db, 'account_enrolled', id, { phone: maskPhone(challenge.phone), email: challenge.email });
    } else {
      db.prepare(
        `UPDATE users SET password_hash = ?, email = COALESCE(email, ?), email_verified_at = COALESCE(email_verified_at, ?)
         WHERE id = ?`,
      ).run(hashPassword(password), challenge.email, at, user.id);
      if (displayName) {
        db.prepare('UPDATE users SET display_name = ? WHERE id = ?').run(displayName, user.id);
      }
      user = db.prepare('SELECT * FROM users WHERE id = ?').get(user.id);
    }

    db.prepare('UPDATE otp_challenges SET consumed_at = ?, user_id = ? WHERE id = ?').run(
      at,
      user.id,
      challenge.id,
    );
    db.prepare('UPDATE users SET phone_verified_at = ?, last_seen_at = ? WHERE id = ?').run(
      at,
      at,
      user.id,
    );
    audit(db, 'password_set_completed', user.id, { phone: maskPhone(challenge.phone) });

    res.json(issueSession(ctx, user, req.body?.device));
  });

  /* ---------------------------------------------------------------------- */
  /* Direct Login with Phone/Email and Password                              */
  /* ---------------------------------------------------------------------- */
  app.post(
    '/api/auth/login',
    loginThrottle(),
    express.json({ limit: '8kb' }),
    (req, res) => {
      const phoneInput = req.body?.phone;
      const usernameInput = req.body?.username;
      const emailInput = req.body?.email ? String(req.body.email).trim().toLowerCase() : null;
      const password = String(req.body?.password ?? '');

      if (!password) return res.status(400).json({ error: 'missing_credentials' });

      let user = null;
      if (phoneInput) {
        try {
          const norm = normalizePhone(req.body?.countryCode ?? '', phoneInput);
          user = db.prepare('SELECT * FROM users WHERE phone = ?').get(norm.phone);
        } catch {
          user = db.prepare('SELECT * FROM users WHERE phone = ?').get(String(phoneInput).replace(/\D/g, ''));
        }

        // STRICT ACCOUNT LOCKING CHECK
        if (user && user.email && emailInput) {
          if (user.email.toLowerCase() !== emailInput) {
            audit(db, 'account_lock_violation_login', user.id, { ip: req.ip, providedEmail: emailInput });
            return res.status(403).json({
              error: 'account_locked',
              message: 'Account locked to another email',
              hint: 'This phone number is permanently paired with a different email address.',
            });
          }
        }
      } else if (emailInput) {
        user = db.prepare('SELECT * FROM users WHERE lower(email) = ?').get(emailInput);
      } else if (usernameInput) {
        user = db.prepare('SELECT * FROM users WHERE lower(username) = ?').get(String(usernameInput).trim().toLowerCase());
      }

      if (!user || !user.password_hash || !verifyPassword(password, user.password_hash)) {
        audit(db, 'login_failed', user?.id ?? null, { ip: req.ip });
        return res.status(401).json({ error: 'invalid_credentials' });
      }

      audit(db, 'login_ok', user.id, { ip: req.ip, device: req.body?.device?.name ?? null });
      res.json(issueSession(ctx, user, req.body?.device));
    },
  );

  app.get('/api/me', requireAuth, (req, res) => {
    res.set('Cache-Control', 'no-store');
    res.json(sessionPayload(db, req.user));
  });

  /** Publish the device's long-term X25519 public key. */
  app.put('/api/me/identity', requireAuth, express.json({ limit: '4kb' }), (req, res) => {
    const key = String(req.body?.publicKey ?? '').trim();
    if (key.length < 32 || key.length > 200) return res.status(400).json({ error: 'invalid_key' });
    db.prepare('UPDATE users SET identity_key = ? WHERE id = ?').run(key, req.user.id);
    audit(db, 'identity_key_set', req.user.id, { key: key.slice(0, 12) });
    const conversation = primaryConversation(db);
    if (conversation) {
      const peer = peerOf(db, conversation.id, req.user.id);
      if (peer) io.to(`user:${peer.id}`).emit('peer:identity', { userId: req.user.id, identityKey: key });
    }
    res.json({ ok: true });
  });

  /* ---------------------------------------------------------------------- */
  /* Automated Contacts & Chat Discovery                                    */
  /* ---------------------------------------------------------------------- */

  /**
   * Discover registered users/contacts on the server, WhatsApp style.
   */
  app.get('/api/contacts', requireAuth, (req, res) => {
    res.set('Cache-Control', 'no-store');
    const contacts = getAllContacts(db, req.user.id);
    res.json({ contacts });
  });

  /**
   * List all conversations for the authenticated user with latest message snippet.
   */
  app.get('/api/conversations', requireAuth, (req, res) => {
    res.set('Cache-Control', 'no-store');
    const conversations = listConversationsForUser(db, req.user.id);
    res.json({ conversations });
  });

  /**
   * Open or initiate a direct chat with a discovered contact.
   */
  app.post('/api/conversations', requireAuth, express.json({ limit: '4kb' }), (req, res) => {
    const peerId = req.body?.peerId ? String(req.body.peerId).trim() : null;
    const phone = req.body?.phone ? String(req.body.phone).replace(/\D/g, '') : null;

    let peer = null;
    if (peerId) {
      peer = db.prepare('SELECT * FROM users WHERE id = ?').get(peerId);
    } else if (phone) {
      peer = db.prepare('SELECT * FROM users WHERE phone = ?').get(phone);
    }

    if (!peer || peer.id === req.user.id) {
      return res.status(404).json({ error: 'peer_not_found', message: 'Target contact not found' });
    }

    const conversation = getOrCreateDirectConversation(db, req.user.id, peer.id);
    res.status(200).json({
      conversation: { id: conversation.id, kind: conversation.kind, createdAt: conversation.created_at },
      peer: serializeUser(peer),
    });
  });

  /** The public directory of contacts + primary peer for backward compatibility. */
  app.get('/api/directory', requireAuth, (req, res) => {
    const conversation = primaryConversation(db);
    const peer = conversation ? peerOf(db, conversation.id, req.user.id) : null;
    const contacts = getAllContacts(db, req.user.id);
    res.set('Cache-Control', 'no-store');
    res.json({
      peer: serializeUser(peer),
      contacts,
    });
  });

  /* ---------------------------------------------------------------------- */
  /* Media - ciphertext in, ciphertext out                                    */
  /* ---------------------------------------------------------------------- */
  app.post(
    '/api/media',
    requireAuth,
    express.raw({ type: '*/*', limit: config.maxMediaBytes }),
    (req, res) => {
      const conversation = primaryConversation(db);
      if (!conversation) return res.status(409).json({ error: 'no_conversation' });

      let meta;
      try {
        meta = JSON.parse(req.get('x-fc-media') ?? '{}');
      } catch {
        return res.status(400).json({ error: 'bad_media_meta' });
      }

      const body = req.body;
      if (!Buffer.isBuffer(body) || body.length === 0) return res.status(400).json({ error: 'empty_body' });
      if (body.length > config.maxMediaBytes) return res.status(413).json({ error: 'too_large' });

      const digest = createHash('sha256').update(body).digest('hex');
      if (meta.sha256 && meta.sha256 !== digest) {
        return res.status(400).json({ error: 'checksum_mismatch' });
      }

      const id = randomUUID();
      const file = path.join(config.mediaDir, `${id}.bin`);
      const stream = createWriteStream(file);
      stream.end(body, () => {
        db.prepare(
          `INSERT INTO media (id, owner_id, conversation_id, size_bytes, sha256, path, created_at)
             VALUES (?, ?, ?, ?, ?, ?, ?)`,
        ).run(
          id,
          req.user.id,
          meta.conversationId ?? conversation.id,
          body.length,
          digest,
          path.relative(config.dataDir, file),
          nowIso(),
        );
        audit(db, 'media_stored', req.user.id, { id, bytes: body.length });
        res.status(201).json({ media: serializeMedia(db.prepare('SELECT * FROM media WHERE id = ?').get(id)) });
      });
      stream.on('error', () => res.status(500).json({ error: 'write_failed' }));
    },
  );

  app.get('/api/media/:id', requireAuth, (req, res) => {
    const row = db.prepare('SELECT * FROM media WHERE id = ?').get(req.params.id);
    if (!row) return res.status(404).json({ error: 'not_found' });
    if (!isMember(db, row.conversation_id, req.user.id)) return res.status(403).json({ error: 'forbidden' });

    const file = path.join(config.dataDir, row.path);
    if (!existsSync(file)) return res.status(410).json({ error: 'gone' });

    res.set('Content-Type', 'application/octet-stream'); // the app unwraps it
    res.set('Cache-Control', 'private, max-age=86400');
    res.set('X-FC-Sha256', row.sha256);
    res.sendFile(file);
  });

  app.delete('/api/media/:id', requireAuth, (req, res) => {
    const row = db.prepare('SELECT * FROM media WHERE id = ?').get(req.params.id);
    if (!row) return res.status(404).json({ error: 'not_found' });
    if (row.owner_id !== req.user.id) return res.status(403).json({ error: 'forbidden' });
    try {
      unlinkSync(path.join(config.dataDir, row.path));
    } catch {
      /* already gone */
    }
    db.prepare('DELETE FROM media WHERE id = ?').run(row.id);
    res.json({ ok: true });
  });

  /* ---------------------------------------------------------------------- */
  /* Cold-start sync: everything newer than the client's cursor              */
  /* ---------------------------------------------------------------------- */
  app.get('/api/sync', requireAuth, (req, res) => {
    const since = Math.max(0, Number.parseInt(req.query.since ?? '0', 10) || 0);
    const limit = Math.min(500, Math.max(1, Number.parseInt(req.query.limit ?? '300', 10) || 300));
    const conversations = conversationIdsFor(db, req.user.id);
    if (conversations.length === 0) {
      return res.json({ messages: [], media: [], latestSeq: since, serverTime: nowIso(), hasMore: false });
    }

    const placeholders = conversations.map(() => '?').join(',');
    const rows = db
      .prepare(
        `SELECT * FROM messages
          WHERE conversation_id IN (${placeholders}) AND seq > ?
          ORDER BY seq ASC LIMIT ?`,
      )
      .all(...conversations, since, limit + 1);

    const hasMore = rows.length > limit;
    const page = hasMore ? rows.slice(0, limit) : rows;

    const mediaIds = [...new Set(page.map((r) => r.media_id).filter(Boolean))];
    const media = mediaIds.length
      ? db
          .prepare(`SELECT * FROM media WHERE id IN (${mediaIds.map(() => '?').join(',')})`)
          .all(...mediaIds)
          .map(serializeMedia)
      : [];

    const latestSeq = db
      .prepare(
        `SELECT COALESCE(MAX(seq), 0) AS seq FROM messages WHERE conversation_id IN (${placeholders})`,
      )
      .get(...conversations).seq;

    res.set('Cache-Control', 'no-store');
    res.json({
      messages: page.map(serializeMessage),
      media,
      latestSeq: Number(latestSeq),
      serverTime: nowIso(),
      hasMore,
    });
  });

  /* ---------------------------------------------------------------------- */
  /* Business tooling documents (catalog, labels, quick replies, auto-reply)  */
  /* ---------------------------------------------------------------------- */
  const readDoc = (userId, section) => {
    const row = db
      .prepare('SELECT * FROM business_docs WHERE user_id = ? AND section = ?')
      .get(userId, section);
    if (!row) return { payload: DEFAULT_BUSINESS[section], rev: 0, updatedAt: null };
    try {
      return { payload: JSON.parse(row.payload), rev: Number(row.rev), updatedAt: row.updated_at };
    } catch {
      return { payload: DEFAULT_BUSINESS[section], rev: Number(row.rev), updatedAt: row.updated_at };
    }
  };

  app.get('/api/business', requireAuth, (req, res) => {
    const docs = {};
    for (const section of BUSINESS_SECTIONS) docs[section] = readDoc(req.user.id, section);
    res.set('Cache-Control', 'no-store');
    res.json({ docs });
  });

  app.get('/api/business/:section', requireAuth, (req, res) => {
    const { section } = req.params;
    if (!BUSINESS_SECTIONS.has(section)) return res.status(404).json({ error: 'unknown_section' });
    res.set('Cache-Control', 'no-store');
    res.json(readDoc(req.user.id, section));
  });

  app.put('/api/business/:section', requireAuth, express.json({ limit: '512kb' }), (req, res) => {
    const { section } = req.params;
    if (!BUSINESS_SECTIONS.has(section)) return res.status(404).json({ error: 'unknown_section' });

    const payload = req.body?.payload;
    const baseRev = Number(req.body?.rev ?? 0);
    if (payload === undefined || typeof payload !== 'object') {
      return res.status(400).json({ error: 'invalid_payload' });
    }

    const current = readDoc(req.user.id, section);
    // Optimistic concurrency: the app always sends the rev it edited.
    if (current.rev !== 0 && baseRev !== current.rev) {
      return res.status(409).json({ error: 'rev_conflict', rev: current.rev, payload: current.payload });
    }

    const rev = current.rev + 1;
    const at = nowIso();
    db.prepare(
      `INSERT INTO business_docs (user_id, section, payload, rev, updated_at)
         VALUES (?, ?, ?, ?, ?)
       ON CONFLICT(user_id, section)
         DO UPDATE SET payload = excluded.payload, rev = excluded.rev, updated_at = excluded.updated_at`,
    ).run(req.user.id, section, JSON.stringify(payload), rev, at);

    // The peer's app can mirror the catalog instantly.
    const conversation = primaryConversation(db);
    if (conversation) {
      const peer = peerOf(db, conversation.id, req.user.id);
      if (peer) {
        io.to(`user:${peer.id}`).emit('business:update', {
          userId: req.user.id,
          section,
          payload,
          rev,
          updatedAt: at,
        });
      }
    }
    res.json({ section, payload, rev, updatedAt: at });
  });

  /** The peer's catalog, read-only, for browsing and sharing. */
  app.get('/api/business/peer/catalog', requireAuth, (req, res) => {
    const conversation = primaryConversation(db);
    const peer = conversation ? peerOf(db, conversation.id, req.user.id) : null;
    if (!peer) return res.json({ items: [] });
    const doc = readDoc(peer.id, 'catalog');
    res.set('Cache-Control', 'no-store');
    res.json({ ownerId: peer.id, ...doc.payload, rev: doc.rev });
  });

  /* ---------------------------------------------------------------------- */
  /* 404 for anything else                                                   */
  /* ---------------------------------------------------------------------- */
  app.use('/api', (req, res) => res.status(404).json({ error: 'not_found' }));
}
