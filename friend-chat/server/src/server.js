import express from 'express';
import { createServer as createHttpServer } from 'node:http';
import { Server as SocketServer } from 'socket.io';

import { loadConfig, log } from './config.js';
import { openDatabase } from './db.js';
import { registerRoutes } from './routes.js';
import { attachRealtime } from './realtime.js';

/**
 * Build the Friend Chat Server without listening - the test suite boots this
 * on an ephemeral port, `src/index.js` boots it for real.
 */
export function buildServer(overrides = {}) {
  const config = loadConfig(overrides);
  const db = openDatabase(config.dbFile);

  const app = express();
  app.disable('x-powered-by');
  app.set('trust proxy', 'loopback');

  // Minimal, privacy-preserving request log: method + path + status only.
  // No bodies, no query strings, no IPs kept beyond memory.
  app.use((req, res, next) => {
    const started = Date.now();
    res.on('finish', () => {
      if (req.path === '/api/health') return;
      log(config, `[http] ${req.method} ${req.path} ${res.statusCode} ${Date.now() - started}ms`);
    });
    next();
  });

  if (config.corsOrigins.length > 0) {
    app.use((req, res, next) => {
      const origin = req.get('origin');
      if (origin && config.corsOrigins.includes(origin)) {
        res.set('Access-Control-Allow-Origin', origin);
        res.set('Vary', 'Origin');
        res.set('Access-Control-Allow-Headers', 'authorization, content-type, x-fc-media');
        res.set('Access-Control-Allow-Methods', 'GET, POST, PUT, DELETE, OPTIONS');
        if (req.method === 'OPTIONS') return res.sendStatus(204);
      }
      next();
    });
  }

  const httpServer = createHttpServer(app);
  const io = new SocketServer(httpServer, {
    cors: { origin: config.corsOrigins.length ? config.corsOrigins : false },
    // WebSocket only: it survives Wi-Fi <-> cellular handoffs far better than
    // HTTP long-polling, and it never leaks a token into a URL.
    transports: ['websocket'],
    pingInterval: 20_000,
    pingTimeout: 25_000,
    maxHttpBufferSize: config.maxEnvelopeChars + 8 * 1024,
  });

  const ctx = { app, config, db, io, httpServer, log };
  registerRoutes(app, ctx);
  attachRealtime(io, ctx);

  return {
    ...ctx,
    async listen() {
      await new Promise((resolve, reject) => {
        httpServer.once('error', reject);
        httpServer.listen(config.port, config.host, resolve);
      });
      return httpServer.address();
    },
    async close() {
      await new Promise((resolve) => io.close(resolve));
      await new Promise((resolve) => httpServer.close(resolve));
      try {
        db.close();
      } catch {
        /* already closed */
      }
    },
  };
}
