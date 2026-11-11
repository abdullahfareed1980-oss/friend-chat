import {
  createHmac,
  randomBytes,
  scryptSync,
  timingSafeEqual,
} from 'node:crypto';

const SCRYPT = { N: 16384, r: 8, p: 1, maxmem: 64 * 1024 * 1024 };
const HEADER = { alg: 'HS256', typ: 'JWT' };
const ISSUER = 'friend-chat-server';

/* -------------------------------------------------------------------------- */
/* Passwords                                                                   */
/* -------------------------------------------------------------------------- */

export function hashPassword(password) {
  const salt = randomBytes(16).toString('hex');
  const hash = scryptSync(password, salt, 64, SCRYPT).toString('hex');
  return `scrypt$${salt}$${hash}`;
}

export function verifyPassword(password, stored) {
  if (typeof stored !== 'string') return false;
  const [algo, salt, hash] = stored.split('$');
  if (algo !== 'scrypt' || !salt || !hash) return false;
  const expected = Buffer.from(hash, 'hex');
  const actual = scryptSync(password, salt, expected.length, SCRYPT);
  return expected.length === actual.length && timingSafeEqual(expected, actual);
}

export function passwordIsWeak(password) {
  return typeof password !== 'string' || password.length < 6;
}

/* -------------------------------------------------------------------------- */
/* Tokens - HS256 JWT, hand rolled so the dependency tree stays at two packages */
/* -------------------------------------------------------------------------- */

const b64url = (value) => Buffer.from(JSON.stringify(value)).toString('base64url');

export function signToken(claims, secret, ttlSeconds) {
  const now = Math.floor(Date.now() / 1000);
  const body = { ...claims, iss: ISSUER, iat: now, exp: now + ttlSeconds };
  const data = `${b64url(HEADER)}.${b64url(body)}`;
  const signature = createHmac('sha256', secret).update(data).digest('base64url');
  return `${data}.${signature}`;
}

export function verifyToken(token, secret) {
  if (typeof token !== 'string') return null;
  const parts = token.split('.');
  if (parts.length !== 3) return null;
  const [header, body, signature] = parts;
  const expected = createHmac('sha256', secret).update(`${header}.${body}`).digest();
  let given;
  try {
    given = Buffer.from(signature, 'base64url');
  } catch {
    return null;
  }
  if (given.length !== expected.length || !timingSafeEqual(given, expected)) return null;

  let claims;
  try {
    claims = JSON.parse(Buffer.from(body, 'base64url').toString('utf8'));
  } catch {
    return null;
  }
  const now = Math.floor(Date.now() / 1000);
  if (claims.iss !== ISSUER) return null;
  if (typeof claims.exp !== 'number' || claims.exp < now) return null;
  return claims;
}

/* -------------------------------------------------------------------------- */
/* Express middleware                                                          */
/* -------------------------------------------------------------------------- */

export function makeRequireAuth(db, config) {
  const byId = db.prepare('SELECT * FROM users WHERE id = ?');

  return function requireAuth(req, res, next) {
    const header = req.get('authorization') ?? '';
    const token = header.startsWith('Bearer ') ? header.slice(7).trim() : null;
    const claims = token ? verifyToken(token, config.jwtSecret) : null;
    if (!claims) return res.status(401).json({ error: 'unauthorized' });

    const user = byId.get(claims.sub);
    if (!user) return res.status(401).json({ error: 'unauthorized' });

    req.user = user;
    req.token = token;
    next();
  };
}

/* -------------------------------------------------------------------------- */
/* Very small brute-force guard for the two-account login                       */
/* -------------------------------------------------------------------------- */

const attempts = new Map();

export function loginThrottle({ windowMs = 15 * 60_000, max = 12 } = {}) {
  return function throttle(req, res, next) {
    const key = req.ip ?? 'unknown';
    const now = Date.now();
    const entry = attempts.get(key);

    if (!entry || now > entry.resetAt) {
      attempts.set(key, { count: 1, resetAt: now + windowMs });
      return next();
    }
    entry.count += 1;
    if (entry.count > max) {
      const retryAfter = Math.ceil((entry.resetAt - now) / 1000);
      res.set('Retry-After', String(retryAfter));
      return res.status(429).json({ error: 'too_many_attempts', retryAfter });
    }
    return next();
  };
}

export function resetThrottle() {
  attempts.clear();
}
