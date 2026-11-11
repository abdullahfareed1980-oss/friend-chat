/**
 * Create the two accounts and their shared conversation.
 *
 *   npm run seed
 *   npm run seed -- --rotate     # reset both numbers/passwords from .env
 *
 * There is deliberately no public sign-up: the only way an account exists is
 * that you ran this command on the machine in your house. The phone numbers it
 * writes are the only two numbers the server will send a login code to.
 */
import { randomUUID } from 'node:crypto';

import { loadConfig, log } from './config.js';
import { openDatabase, nowIso } from './db.js';
import { hashPassword, passwordIsWeak } from './auth.js';
import { normalizePhone } from './phone.js';

function readPeople() {
  return [
    {
      label: 'A',
      username: (process.env.SEED_USER_A_USERNAME ?? 'hana').trim().toLowerCase(),
      password: process.env.SEED_USER_A_PASSWORD ?? '',
      displayName: (process.env.SEED_USER_A_DISPLAY_NAME ?? 'Hana').trim(),
      phone: process.env.SEED_USER_A_PHONE ?? '+62 812 3456 7890',
      businessName: (process.env.SEED_USER_A_BUSINESS_NAME ?? '').trim() || null,
      accent: process.env.SEED_USER_A_ACCENT ?? '#4F46E5',
    },
    {
      label: 'B',
      username: (process.env.SEED_USER_B_USERNAME ?? 'omar').trim().toLowerCase(),
      password: process.env.SEED_USER_B_PASSWORD ?? '',
      displayName: (process.env.SEED_USER_B_DISPLAY_NAME ?? 'Omar').trim(),
      phone: process.env.SEED_USER_B_PHONE ?? '+62 811 9876 5432',
      businessName: (process.env.SEED_USER_B_BUSINESS_NAME ?? '').trim() || null,
      accent: process.env.SEED_USER_B_ACCENT ?? '#34D399',
    },
  ];
}

/** Split "+62 812 3456 7890" into a plausible country code and subscriber part. */
function splitSeededPhone(raw) {
  const cleaned = String(raw ?? '').trim();
  const match = cleaned.match(/^\+\s*(\d{1,4})[\s-]*(.*)$/);
  if (match) return normalizePhone(`+${match[1]}`, match[2]);
  // No '+' given: assume the whole string is the national number of the
  // default country configured below.
  return normalizePhone(process.env.SEED_DEFAULT_COUNTRY_CODE ?? '+62', cleaned);
}

export function seedUsers(db, people) {
  const at = nowIso();
  const created = [];

  const insertUser = db.prepare(
    `INSERT INTO users (id, username, display_name, password_hash, phone, country_code, phone_verified_at, email, email_verified_at, is_business, business_name, accent_color, created_at)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
  );
  const updateExisting = db.prepare(
    `UPDATE users SET password_hash = ?, display_name = ?, phone = ?, country_code = ?, email = COALESCE(?, email), email_verified_at = COALESCE(?, email_verified_at), business_name = ?
      WHERE id = ?`,
  );
  const findByUsername = db.prepare('SELECT * FROM users WHERE username = ?');
  const findByPhone = db.prepare('SELECT * FROM users WHERE phone = ?');

  for (const person of people) {
    const normalized = splitSeededPhone(person.phone);
    if (normalized.phone.length < 8) {
      throw new Error(`SEED_USER_${person.label}_PHONE looks too short: ${person.phone}`);
    }

    const clash = findByPhone.get(normalized.phone);
    const existing = findByUsername.get(person.username);
    if (clash && (!existing || clash.id !== existing.id)) {
      throw new Error(`phone ${normalized.phone} is already used by another account`);
    }

    const userEmail = person.email ?? `${person.username}@friendchat.local`;

    if (existing) {
      updateExisting.run(
        hashPassword(person.password),
        person.displayName,
        normalized.phone,
        normalized.countryCode,
        userEmail,
        at,
        person.businessName,
        existing.id,
      );
      created.push({ ...findByUsername.get(person.username), normalized, updated: true });
    } else {
      const id = randomUUID();
      insertUser.run(
        id,
        person.username,
        person.displayName,
        hashPassword(person.password),
        normalized.phone,
        normalized.countryCode,
        at,
        userEmail,
        at,
        person.businessName ? 1 : 0,
        person.businessName,
        person.accent,
        at,
      );
      created.push({ ...findByUsername.get(person.username), normalized, updated: false });
    }
  }

  let conversation = db.prepare("SELECT * FROM conversations WHERE kind = 'direct' LIMIT 1").get();
  if (!conversation) {
    const conversationId = randomUUID();
    db.prepare('INSERT INTO conversations (id, kind, created_at) VALUES (?, ?, ?)').run(
      conversationId,
      'direct',
      at,
    );
    conversation = { id: conversationId, kind: 'direct', created_at: at };
  }

  const addMember = db.prepare(
    'INSERT OR IGNORE INTO conversation_members (conversation_id, user_id) VALUES (?, ?)',
  );
  for (const person of created) addMember.run(conversation.id, person.id);

  return { users: created, conversation };
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const rotate = process.argv.includes('--rotate');
  const config = loadConfig();
  const db = openDatabase(config.dbFile);

  const people = readPeople();

  for (const person of people) {
    if (passwordIsWeak(person.password)) {
      console.error(
        `\n  SEED_USER_${person.label}_PASSWORD is missing or shorter than 12 characters.\n` +
          `  Copy .env.example to .env, set both passwords and both phone numbers, then\n` +
          `  re-run: npm run seed\n`,
      );
      process.exit(1);
    }
  }

  if (!rotate) {
    const count = Number(db.prepare('SELECT COUNT(*) AS n FROM users').get().n);
    if (count > 0) {
      console.error(
        `\n  ${count} account(s) already exist. Pass --rotate to update them:\n` +
          `      npm run seed -- --rotate\n`,
      );
      process.exit(1);
    }
  }

  const { users, conversation } = seedUsers(db, people);

  console.log('');
  console.log('  Friend Chat accounts ready:');
  for (const user of users) {
    console.log(
      `    • ${user.username.padEnd(12)} ${user.display_name.padEnd(14)} ${user.normalized.countryCode} ${user.normalized.nationalNumber}`,
    );
  }
  console.log(`    conversation ${conversation.id}`);
  console.log('');
  console.log('  Those two numbers are the only ones the server will send a code to.');
  console.log('  The next sign-in code is printed in this terminal.');
  console.log('');

  log(config, 'seed complete');
  db.close();
}
