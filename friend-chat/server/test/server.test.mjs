import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { createHash, randomUUID } from 'node:crypto';
import { io as ioClient } from 'socket.io-client';

import { buildServer } from '../src/server.js';
import { seedUsers } from '../src/seed.js';

const dataDir = mkdtempSync(path.join(os.tmpdir(), 'friend-chat-test-'));
const server = buildServer({
  dataDir,
  port: 0,
  jwtSecret: 'test-secret-not-used-anywhere-real',
  isTest: true,
  logLevel: 'silent',
  skipDotEnv: true,
  maxUsers: 2,
  allowRegistration: false,
  otp: {
    ttlSeconds: 600,
    resendSeconds: 60,
    maxAttempts: 5,
    maxPerHour: 8,
    debug: true, // lets the test read the code from the response
    delivery: 'console',
  },
});

const PEOPLE = [
  {
    username: 'hana',
    password: 'hana-local-password-1',
    displayName: 'Hana',
    phone: '+62 812 3456 7890',
    businessName: 'Hana Studio',
    accent: '#4F46E5',
  },
  {
    username: 'omar',
    password: 'omar-local-password-2',
    displayName: 'Omar',
    phone: '+62 811 9876 5432',
    businessName: null,
    accent: '#34D399',
  },
];

const { users, conversation } = seedUsers(server.db, PEOPLE);
const [hana, omar] = users;
let base;
let tokenA;
let tokenB;

const api = (route, options = {}) =>
  fetch(`${base}${route}`, {
    ...options,
    headers: {
      'content-type': 'application/json',
      ...(options.token ? { authorization: `Bearer ${options.token}` } : {}),
      ...(options.headers ?? {}),
    },
    body: options.body ? JSON.stringify(options.body) : undefined,
  });

const liveSockets = new Set();
const roleSockets = { a: new Set(), b: new Set() };

async function closeAll() {
  for (const socket of [...liveSockets]) socket.close();
  liveSockets.clear();
  roleSockets.a.clear();
  roleSockets.b.clear();
  await new Promise((resolve) => setTimeout(resolve, 250));
}

/** Close only one person's sockets, so the other side can observe presence. */
async function closeRole(role) {
  for (const socket of [...(roleSockets[role] ?? [])]) socket.close();
  roleSockets[role]?.clear();
  await new Promise((resolve) => setTimeout(resolve, 250));
}

function connect(token, { role } = {}) {
  const socket = ioClient(base, {
    transports: ['websocket'],
    reconnection: false,
    auth: { token, device: { id: randomUUID(), name: 'test-phone', platform: 'test' } },
  });
  // The server greets on connect; capture it before the socket opens so the
  // packet is never missed.
  socket.fcHello = new Promise((resolve, reject) => {
    socket.once('server:hello', resolve);
    socket.once('connect_error', reject);
    setTimeout(() => reject(new Error('timeout waiting for server:hello')), 3000).unref?.();
  });
  socket.fcHello.catch(() => {});
  liveSockets.add(socket);
  if (role) roleSockets[role]?.add(socket);
  socket.on('disconnect', () => {
    liveSockets.delete(socket);
    if (role) roleSockets[role]?.delete(socket);
  });

  return new Promise((resolve, reject) => {
    socket.once('connect', () => resolve(socket));
    socket.once('connect_error', reject);
  });
}

const once = (socket, event) =>
  new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error(`timeout waiting for ${event}`)), 3000);
    socket.once(event, (payload) => {
      clearTimeout(timer);
      resolve(payload);
    });
  });

const emit = (socket, event, payload) =>
  new Promise((resolve) => socket.emit(event, payload, resolve));

/** Stand-in for the app's X25519+AES-GCM envelope: opaque base64 to the server. */
const envelope = (text) =>
  Buffer.from(
    JSON.stringify({ v: 1, alg: 'x25519-aesgcm', ct: Buffer.from(text).toString('base64') }),
  ).toString('base64');

const requestOtp = (phone, countryCode = '+62') =>
  api('/api/auth/request-otp', { method: 'POST', body: { countryCode, phone } });

test('Friend Chat Server', async (t) => {
  const address = await server.listen();
  base = `http://127.0.0.1:${address.port}`;

  t.after(async () => {
    await closeAll();
    await server.close();
  });

  await t.test('health reports a private two-person server', async () => {
    const res = await api('/api/health');
    assert.equal(res.status, 200);
    const body = await res.json();
    assert.equal(body.ok, true);
    assert.equal(body.maxUsers, 2);
    assert.equal(body.users, 2);
    assert.equal(body.e2ee, true);
    assert.equal(body.registrationOpen, false);
    assert.equal(body.otpDelivery, 'console');
  });

  await t.test('onboarding: OTP request, throttling, wrong code, success', async () => {
    const first = await requestOtp('812 3456 7890');
    assert.equal(first.status, 200);
    const challenge = await first.json();
    assert.equal(challenge.phone, '6281234567890');
    assert.equal(challenge.countryCode, '+62');
    assert.equal(challenge.delivery, 'console');
    assert.equal(challenge.known, true);
    assert.match(challenge.devCode, /^\d{6}$/);

    // Immediate resend is refused.
    const tooSoon = await requestOtp('812 3456 7890');
    assert.equal(tooSoon.status, 429);
    assert.equal((await tooSoon.json()).error, 'resend_too_soon');

    // A wrong code burns an attempt but not the challenge.
    const wrong = String((Number(challenge.devCode) + 1) % 1000000).padStart(6, '0');
    const bad = await api('/api/auth/verify-otp', {
      method: 'POST',
      body: { challengeId: challenge.challengeId, code: wrong },
    });
    assert.equal(bad.status, 401);
    const badBody = await bad.json();
    assert.equal(badBody.error, 'invalid_code');
    assert.equal(badBody.attemptsRemaining, 4);

    // The right code signs Hana in.
    const ok = await api('/api/auth/verify-otp', {
      method: 'POST',
      body: {
        challengeId: challenge.challengeId,
        code: challenge.devCode,
        device: { id: 'dev-a', name: 'Pixel 8', platform: 'android' },
      },
    });
    assert.equal(ok.status, 200);
    const session = await ok.json();
    assert.ok(session.token);
    assert.equal(session.user.id, hana.id);
    assert.equal(session.user.phone, '6281234567890');
    assert.equal(session.user.phoneVerified, true);
    assert.equal(session.peer.id, omar.id);
    assert.equal(session.conversation.id, conversation.id);
    tokenA = session.token;

    // A challenge is single use.
    const reuse = await api('/api/auth/verify-otp', {
      method: 'POST',
      body: { challengeId: challenge.challengeId, code: challenge.devCode },
    });
    assert.equal(reuse.status, 409);
  });

  await t.test('onboarding: refuses numbers that are not enrolled', async () => {
    const res = await requestOtp('899 9999 9999');
    assert.equal(res.status, 403);
    assert.equal((await res.json()).error, 'phone_not_enrolled');
  });

  await t.test('onboarding: rejects malformed numbers and unknown challenges', async () => {
    const badCc = await requestOtp('81234567', '+99999');
    assert.equal(badCc.status, 400);
    assert.equal((await badCc.json()).error, 'invalid_country_code');

    const noChallenge = await api('/api/auth/verify-otp', {
      method: 'POST',
      body: { challengeId: randomUUID(), code: '123456' },
    });
    assert.equal(noChallenge.status, 404);
  });

  await t.test('fallback password login still works for the owner', async () => {
    const res = await api('/api/auth/login', {
      method: 'POST',
      body: { username: 'omar', password: PEOPLE[1].password },
    });
    assert.equal(res.status, 200);
    const session = await res.json();
    tokenB = session.token;
    assert.ok(tokenB);

    const bad = await api('/api/auth/login', {
      method: 'POST',
      body: { username: 'omar', password: 'wrong-password-here' },
    });
    assert.equal(bad.status, 401);
  });

  await t.test('rejects unauthenticated REST and socket access', async () => {
    assert.equal((await api('/api/sync')).status, 401);
    assert.equal((await api('/api/me', { token: `${tokenA.slice(0, -3)}abc` })).status, 401);
    await assert.rejects(() => connect('nope'), /unauthorized/);
  });

  await t.test('delivers a message in real time with idempotent retries', async () => {
    // Connect the peer first so Hana's greeting reports peerOnline.
    const socketB = await connect(tokenB);
    const socketA = await connect(tokenA);
    t.after(() => {
      socketA.close();
      socketB.close();
    });

    const helloA = await socketA.fcHello;
    const helloB = await socketB.fcHello;
    assert.equal(helloB.conversation.id, conversation.id);
    assert.equal(helloA.peerOnline, true);

    const incoming = once(socketB, 'message:new');
    const clientId = randomUUID();
    const payload = envelope('meet at the pier at 7?');
    const ack = await emit(socketA, 'message:send', {
      conversationId: conversation.id,
      clientId,
      kind: 'text',
      envelope: payload,
    });

    assert.equal(ack.ok, true);
    assert.equal(ack.message.seq, 1);
    assert.equal(ack.message.envelope, payload, 'server must not transform the envelope');

    const delivered = await incoming;
    assert.equal(delivered.uuid, ack.message.uuid);
    assert.equal(delivered.senderId, hana.id);

    const retry = await emit(socketA, 'message:send', {
      conversationId: conversation.id,
      clientId,
      kind: 'text',
      envelope: payload,
    });
    assert.equal(retry.ok, true);
    assert.equal(retry.duplicate, true);
    assert.equal(retry.message.seq, 1);

    assert.equal(Number(server.db.prepare('SELECT COUNT(*) AS n FROM messages').get().n), 1);
  });

  await t.test('propagates delivered then read receipts to the sender', async () => {
    const socketA = await connect(tokenA);
    const socketB = await connect(tokenB);
    t.after(() => {
      socketA.close();
      socketB.close();
    });

    const deliveredEvent = once(socketA, 'receipt:update');
    assert.equal((await emit(socketB, 'receipt:delivered', { seqs: [1] })).ok, true);
    const delivered = await deliveredEvent;
    assert.equal(delivered.status, 'delivered');
    assert.equal(delivered.upToSeq, 1);

    const readEvent = once(socketA, 'receipt:update');
    assert.equal(
      (await emit(socketB, 'receipt:read', { conversationId: conversation.id, upToSeq: 1 })).ok,
      true,
    );
    const read = await readEvent;
    assert.equal(read.status, 'read');
    assert.equal(read.by, omar.id);

    const row = server.db.prepare('SELECT * FROM messages WHERE seq = 1').get();
    assert.ok(row.delivered_at);
    assert.ok(row.read_at);
  });

  await t.test('replays missed messages from the seq cursor (offline catch-up)', async () => {
    const socketB = await connect(tokenB);
    t.after(() => socketB.close());

    const ack = await emit(socketB, 'message:send', {
      conversationId: conversation.id,
      clientId: randomUUID(),
      kind: 'text',
      envelope: envelope('got it, see you there'),
    });
    assert.equal(ack.ok, true);
    assert.equal(ack.message.seq, 2);

    const sync = await (await api('/api/sync?since=1', { token: tokenA })).json();
    assert.equal(sync.messages.length, 1);
    assert.equal(sync.messages[0].senderId, omar.id);
    assert.equal(sync.latestSeq, 2);
    assert.equal(sync.hasMore, false);

    const nothing = await (await api('/api/sync?since=2', { token: tokenA })).json();
    assert.equal(nothing.messages.length, 0);

    // Socket-level catch-up uses the same cursor.
    const socketA = await connect(tokenA);
    t.after(() => socketA.close());
    const result = await emit(socketA, 'sync:request', { sinceSeq: 0 });
    assert.equal(result.ok, true);
    assert.equal(result.messages.length, 2);
  });

  await t.test('stores ciphertext media and serves it back to the peer only', async () => {
    const payload = Buffer.from('ciphertext-bytes-from-the-phone');
    const sha256 = createHash('sha256').update(payload).digest('hex');

    const upload = await fetch(`${base}/api/media`, {
      method: 'POST',
      headers: {
        authorization: `Bearer ${tokenA}`,
        'content-type': 'application/octet-stream',
        'x-fc-media': JSON.stringify({ conversationId: conversation.id, sha256 }),
      },
      body: payload,
    });
    assert.equal(upload.status, 201);
    const { media } = await upload.json();
    assert.equal(media.sizeBytes, payload.length);

    const download = await fetch(`${base}/api/media/${media.id}`, {
      headers: { authorization: `Bearer ${tokenB}` },
    });
    assert.equal(download.status, 200);
    assert.equal(download.headers.get('content-type'), 'application/octet-stream');
    assert.deepEqual(Buffer.from(await download.arrayBuffer()), payload);

    const badChecksum = await fetch(`${base}/api/media`, {
      method: 'POST',
      headers: {
        authorization: `Bearer ${tokenA}`,
        'content-type': 'application/octet-stream',
        'x-fc-media': JSON.stringify({ sha256: 'deadbeef' }),
      },
      body: payload,
    });
    assert.equal(badChecksum.status, 400);
  });

  await t.test('syncs business documents with optimistic concurrency', async () => {
    assert.equal((await (await api('/api/business/catalog', { token: tokenB })).json()).rev, 0);

    const put = await api('/api/business/catalog', {
      method: 'PUT',
      token: tokenB,
      body: {
        rev: 0,
        payload: {
          items: [{ id: 'p1', name: 'Hand-thrown mug', priceCents: 2400, currency: 'EUR', active: true }],
        },
      },
    });
    assert.equal(put.status, 200);
    assert.equal((await put.json()).rev, 1);

    const stale = await api('/api/business/catalog', {
      method: 'PUT',
      token: tokenB,
      body: { rev: 0, payload: { items: [] } },
    });
    assert.equal(stale.status, 409);
    const conflict = await stale.json();
    assert.equal(conflict.rev, 1);
    assert.equal(conflict.payload.items[0].name, 'Hand-thrown mug');

    const peerCatalog = await (await api('/api/business/peer/catalog', { token: tokenA })).json();
    assert.equal(peerCatalog.items.length, 1);
    assert.equal(peerCatalog.ownerId, omar.id);

    assert.equal((await (await api('/api/business/labels', { token: tokenA })).json()).rev, 0);
  });

  await t.test('shares the peer encryption key and presence transitions', async () => {
    const put = await api('/api/me/identity', {
      method: 'PUT',
      token: tokenB,
      body: { publicKey: 'omar-public-key-base64-placeholder-value-1234567890' },
    });
    assert.equal(put.status, 200);

    const directory = await (await api('/api/directory', { token: tokenA })).json();
    assert.equal(directory.peer.id, omar.id);
    assert.ok(directory.peer.identityKey.includes('omar-public-key'));

    // Start from a clean connection table so presence transitions are crisp.
    await closeAll();

    const socketA = await connect(tokenA, { role: 'a' });
    await connect(tokenB, { role: 'b' });
    const socketA2 = await connect(tokenA, { role: 'a' });
    const helloA2 = await socketA2.fcHello;
    assert.equal(helloA2.peerOnline, true, 'a fresh device sees the peer already online');

    const offline = once(socketA, 'presence');
    await closeRole('b');
    const off = await offline;
    assert.equal(off.userId, omar.id);
    assert.equal(off.online, false);

    const online = once(socketA, 'presence');
    await connect(tokenB, { role: 'b' });
    const on = await online;
    assert.equal(on.userId, omar.id);
    assert.equal(on.online, true);
  });

  await t.test('tombstones a deleted message without leaking its body', async () => {
    const socketA = await connect(tokenA);
    t.after(() => socketA.close());

    const ack = await emit(socketA, 'message:send', {
      conversationId: conversation.id,
      clientId: randomUUID(),
      kind: 'text',
      envelope: envelope('this will be deleted'),
    });
    assert.equal(ack.ok, true);

    assert.equal((await emit(socketA, 'message:delete', { uuid: ack.message.uuid })).ok, true);

    const row = server.db.prepare('SELECT * FROM messages WHERE uuid = ?').get(ack.message.uuid);
    assert.ok(row.deleted_at);
    assert.equal(row.envelope, '');
  });

  /* ---------------------------------------------------------------------- */
  /* New WhatsApp-Alternative Flows: Auto-Registration, 2-Step & Discovery  */
  /* ---------------------------------------------------------------------- */

  await t.test('auto-registration: zero manual seeding, Gmail OTP, and 2-step password', async () => {
    // Open registration for auto-registration test
    server.config.allowRegistration = true;
    server.config.maxUsers = 1_000_000;

    // 1. Request OTP with new phone and Gmail
    const reqRes = await api('/api/auth/request-otp', {
      method: 'POST',
      body: { countryCode: '+1', phone: '415 555 2671', email: 'alex@gmail.com' },
    });
    assert.equal(reqRes.status, 200);
    const challenge = await reqRes.json();
    assert.equal(challenge.phone, '14155552671');
    assert.equal(challenge.email, 'alex@gmail.com');
    assert.equal(challenge.known, false);
    assert.match(challenge.devCode, /^\d{6}$/);

    // 2. Verify OTP without password -> prompts for 2-step password setup
    const verifyRes = await api('/api/auth/verify-otp', {
      method: 'POST',
      body: { challengeId: challenge.challengeId, code: challenge.devCode },
    });
    assert.equal(verifyRes.status, 200);
    const verifyData = await verifyRes.json();
    assert.equal(verifyData.verifiedOtp, true);
    assert.equal(verifyData.needsPassword, true);

    // 3. Complete Two-Step Verification by setting account password
    const setPassRes = await api('/api/auth/set-password', {
      method: 'POST',
      body: {
        challengeId: challenge.challengeId,
        password: 'SuperSecretPassword123!',
        displayName: 'Alex Morgan',
      },
    });
    assert.equal(setPassRes.status, 200);
    const session = await setPassRes.json();
    assert.ok(session.token);
    assert.equal(session.user.phone, '14155552671');
    assert.equal(session.user.email, 'alex@gmail.com');
    assert.equal(session.user.displayName, 'Alex Morgan');

    // 4. Verify SQLite database permanently bound phone, email, and password_hash
    const userRow = server.db.prepare('SELECT * FROM users WHERE phone = ?').get('14155552671');
    assert.ok(userRow);
    assert.equal(userRow.email, 'alex@gmail.com');
    assert.ok(userRow.password_hash.startsWith('scrypt$'));
  });

  await t.test('strict account locking: rejects mismatched email with 403 Forbidden', async () => {
    // Attempt OTP with Alex's phone but someone else's email
    const lockedRes = await api('/api/auth/request-otp', {
      method: 'POST',
      body: { countryCode: '+1', phone: '415 555 2671', email: 'impostor@gmail.com' },
    });
    assert.equal(lockedRes.status, 403);
    const body = await lockedRes.json();
    assert.equal(body.error, 'account_locked');
    assert.equal(body.message, 'Account locked to another email');

    // Attempt direct password login with mismatched email
    const loginLocked = await api('/api/auth/login', {
      method: 'POST',
      body: {
        phone: '14155552671',
        email: 'wrong@gmail.com',
        password: 'SuperSecretPassword123!',
      },
    });
    assert.equal(loginLocked.status, 403);
    assert.equal((await loginLocked.json()).error, 'account_locked');

    // Correct email and password succeeds
    const loginOk = await api('/api/auth/login', {
      method: 'POST',
      body: {
        phone: '14155552671',
        email: 'alex@gmail.com',
        password: 'SuperSecretPassword123!',
      },
    });
    assert.equal(loginOk.status, 200);
    assert.ok((await loginOk.json()).token);
  });

  await t.test('automated contacts and chat discovery', async () => {
    // Login as Alex
    const login = await api('/api/auth/login', {
      method: 'POST',
      body: {
        phone: '14155552671',
        email: 'alex@gmail.com',
        password: 'SuperSecretPassword123!',
      },
    });
    const { token: alexToken, user: alexUser } = await login.json();

    // 1. Discover all registered contacts on the server
    const contactsRes = await api('/api/contacts', { token: alexToken });
    assert.equal(contactsRes.status, 200);
    const { contacts } = await contactsRes.json();
    assert.ok(Array.isArray(contacts));
    assert.ok(contacts.length >= 2, 'discovers other users (Hana, Omar)');
    assert.ok(contacts.some((c) => c.displayName === 'Hana'));

    // 2. Start a direct chat with Hana
    const hanaContact = contacts.find((c) => c.displayName === 'Hana');
    const startChat = await api('/api/conversations', {
      method: 'POST',
      token: alexToken,
      body: { peerId: hanaContact.id },
    });
    assert.equal(startChat.status, 200);
    const { conversation: directConv, peer } = await startChat.json();
    assert.ok(directConv.id);
    assert.equal(peer.id, hanaContact.id);

    // 3. List conversations
    const convListRes = await api('/api/conversations', { token: alexToken });
    assert.equal(convListRes.status, 200);
    const { conversations } = await convListRes.json();
    assert.ok(conversations.some((c) => c.conversation.id === directConv.id));
  });
});
