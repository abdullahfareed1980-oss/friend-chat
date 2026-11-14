import os from 'node:os';
import { buildServer } from './server.js';

const server = buildServer();
const address = await server.listen();
const { config } = server;

function lanAddresses() {
  const out = [];
  for (const [name, addrs] of Object.entries(os.networkInterfaces())) {
    for (const addr of addrs ?? []) {
      if (addr.family === 'IPv4' && !addr.internal) out.push({ name, address: addr.address });
    }
  }
  return out;
}

const users = Number(server.db.prepare('SELECT COUNT(*) AS n FROM users').get().n);

console.log('');
console.log('  ┌────────────────────────────────────────────────────────────┐');
console.log('  │  Friend Chat Server — WhatsApp Alternative Messaging       │');
console.log('  │  Production & Cloud Ready • E2EE • Zero Terminal Seeding  │');
console.log('  └────────────────────────────────────────────────────────────┘');
console.log('');
console.log(`  listening     http://${config.host}:${address.port}`);
console.log(`  websocket     ws://${config.host}:${address.port}/socket.io/`);
console.log(`  database      ${config.dbFile} (SQLite WAL)`);
console.log(`  media         ${config.mediaDir}`);
console.log(`  onboarding    Automated Gmail OTP (Zero manual seeding required)`);
console.log(`  security      Two-Step Verification & Permanent Account Locking`);
console.log(`  mailer        Nodemailer (${config.smtp.host}:${config.smtp.port})`);
console.log(`  users         ${users} registered account(s)`);
console.log('');
console.log('  Reachable on this machine / LAN:');
console.log(`    http://127.0.0.1:${address.port}`);
for (const { name, address: ip } of lanAddresses()) {
  console.log(`    http://${ip}:${address.port}   (${name})`);
}
console.log('');

/* -------------------------------------------------------------------------- */
/* Graceful shutdown so SQLite always closes cleanly                           */
/* -------------------------------------------------------------------------- */
let shuttingDown = false;
for (const signal of ['SIGINT', 'SIGTERM']) {
  process.on(signal, async () => {
    if (shuttingDown) return;
    shuttingDown = true;
    console.log(`\n[friend-chat] ${signal} received, closing...`);
    try {
      await server.close();
    } finally {
      process.exit(0);
    }
  });
}

process.on('unhandledRejection', (err) => {
  console.error('[friend-chat] unhandled rejection:', err);
});
