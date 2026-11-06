import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { randomBytes } from 'node:crypto';
import path from 'node:path';

const cwd = process.cwd();

/** Load .env if present. Node 20.12+ exposes process.loadEnvFile. */
function loadDotEnv() {
  const file = path.join(cwd, '.env');
  if (!existsSync(file)) return;
  try {
    process.loadEnvFile(file);
  } catch (err) {
    console.warn(`[friend-chat] could not read .env: ${err.message}`);
  }
}

function readOrCreateSecret(file) {
  if (existsSync(file)) return readFileSync(file, 'utf8').trim();
  const secret = randomBytes(48).toString('base64url');
  writeFileSync(file, secret, { mode: 0o600 });
  console.log('[friend-chat] generated a new token signing key at', file);
  return secret;
}

function int(value, fallback) {
  const n = Number.parseInt(value ?? '', 10);
  return Number.isFinite(n) ? n : fallback;
}

function list(value) {
  return (value ?? '')
    .split(',')
    .map((s) => s.trim())
    .filter(Boolean);
}

/**
 * Build the runtime configuration. `overrides` wins over .env, which is what
 * the test suite uses to get an isolated temp directory.
 */
export function loadConfig(overrides = {}) {
  if (!overrides.skipDotEnv) loadDotEnv();

  const dataDir = path.resolve(
    overrides.dataDir ?? process.env.DATA_DIR ?? path.join(cwd, 'data'),
  );
  const mediaDir = path.join(dataDir, 'media');
  mkdirSync(mediaDir, { recursive: true });

  const config = {
    // --- identity of this service -------------------------------------------
    serviceName: 'Friend Chat Server',
    version: '1.0.0',

    // --- network -------------------------------------------------------------
    host: process.env.HOST ?? '0.0.0.0',
    port: int(process.env.PORT, 8787),
    corsOrigins: list(process.env.CORS_ORIGINS),

    // --- storage -------------------------------------------------------------
    dataDir,
    mediaDir,
    dbFile: path.join(dataDir, 'friend-chat.db'),

    // --- security ------------------------------------------------------------
    jwtSecret: process.env.JWT_SECRET?.trim()
      ? process.env.JWT_SECRET.trim()
      : readOrCreateSecret(path.join(dataDir, 'jwt.secret')),
    tokenTtlSeconds: int(process.env.TOKEN_TTL_SECONDS, 60 * 60 * 24 * 30),

    // --- WhatsApp-style OTP onboarding --------------------------------------
    otp: {
      ttlSeconds: int(process.env.OTP_TTL_SECONDS, 600), // 10 minutes
      resendSeconds: int(process.env.OTP_RESEND_SECONDS, 60),
      maxAttempts: int(process.env.OTP_MAX_ATTEMPTS, 5),
      maxPerHour: int(process.env.OTP_MAX_PER_HOUR, 8),
      // Development only: returns the code in the HTTP response so you can
      // test on a LAN without reading the server terminal. NEVER in production.
      debug: process.env.OTP_DEBUG === 'true',
      // How the code reaches a human. 'console' = printed by the server you own.
      delivery: process.env.OTP_DELIVERY ?? 'console',
    },

    // --- limits --------------------------------------------------------------
    maxMediaBytes: int(process.env.MAX_MEDIA_BYTES, 25 * 1024 * 1024),
    maxEnvelopeChars: int(process.env.MAX_ENVELOPE_CHARS, 96 * 1024),
    maxUsers: int(process.env.MAX_USERS, 2),
    allowRegistration: process.env.ALLOW_REGISTRATION === 'true',

    // --- misc ----------------------------------------------------------------
    logLevel: process.env.LOG_LEVEL ?? 'info',
    isTest: process.env.NODE_ENV === 'test',
  };

  return { ...config, ...overrides, dataDir, mediaDir, dbFile: path.join(dataDir, 'friend-chat.db') };
}

export function log(config, ...args) {
  if (config.isTest && config.logLevel !== 'debug') return;
  console.log(new Date().toISOString(), ...args);
}
