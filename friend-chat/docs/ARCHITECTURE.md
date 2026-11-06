# Architecture

## 1. The shape of the system

Three pieces, no fourth:

```
┌─────────────────────────── Android APK ───────────────────────────┐
│  UI (Material 3, Friend Chat theme)                               │
│  ChatController ──► CryptoService ──► SocketService ──┐           │
│       │                    │                          │           │
│       ├──► Hive (encrypted cache, seq cursor)         │           │
│       └──► ConnectionManager (races endpoints)        │           │
│  BackgroundChatService (Android foreground dataSync)  │           │
│  NotificationService (local only, no FCM)             │           │
└───────────────────────────────────────────────────────┼───────────┘
                                                        │ wss
┌──────────────────────────── Windows .exe ─────────────┼───────────┐
│  same Dart code, same controllers, no foreground svc  │           │
└───────────────────────────────────────────────────────┼───────────┘
                                                        ▼
┌────────────────────── Friend Chat Server ─────────────────────────┐
│  Express (REST)          Socket.io (realtime)                     │
│  /api/auth/*             message:send   receipt:delivered         │
│  /api/sync               receipt:read   typing                    │
│  /api/media              sync:request   presence                  │
│  /api/business/*         message:delete business:update           │
│                                                                   │
│  SQLite (WAL): users, otp_challenges, conversations, messages,    │
│                media, business_docs, devices, audit_log           │
│  Disk: data/media/<uuid>.bin  (ciphertext)                        │
└───────────────────────────────────────────────────────────────────┘
```

There is no message queue, no Redis, no object store, no push service. One Node
process and one SQLite file is the correct amount of infrastructure for two
people, and it is the amount a human can actually audit.

## 2. One message, end to end

```
 Hana types "meet at 7"
 ─────────────────────────────────────────────────────────────────────────
 1. ChatController builds EnvelopeBody{text:"meet at 7"} as JSON
 2. CryptoService: fresh X25519 ephemeral key pair
                   ECDH with Omar's published identity key
                   HKDF-SHA256 -> 32-byte AES key (bound to conv id + direction)
                   AES-256-GCM -> ciphertext + nonce
 3. Envelope {v:1, alg:"x25519-aesgcm", from, epk, n, ct} -> base64
 4. Optimistic bubble inserted with status=sending, seq=0, clientId=uuid
 5. socket.emit("message:send", {conversationId, clientId, envelope}, ack)
 ─────────────────────────────────────────────────────────────────────────
 Server:
 6. authenticate socket, verify membership, validate size
 7. INSERT ... UNIQUE(sender_id, client_id)  ->  retries cannot duplicate
 8. seq = AUTOINCREMENT  (global ordering cursor)
 9. emit "message:new" to the peer's room (+ sender's other devices)
10. ack {ok, message:{uuid, seq, createdAt, ...}}
 ─────────────────────────────────────────────────────────────────────────
11. Sender: ack replaces the optimistic row, status=sent, one tick
12. Omar's device: decrypts, persists, status unread, emits receipt:delivered
13. Sender receives receipt:update -> two ticks
14. Omar opens the chat -> receipt:read -> two mint ticks
```

Steps 12–14 are why the ticks are honest: "delivered" means *persisted on Omar's
device*, not "accepted by the server".

## 3. Offline and catch-up

`messages.seq` is a single monotonic counter. Each device persists the highest
seq it holds (`LocalStore.cursor`). On every start, reconnect and network
handoff:

```
GET /api/sync?since=<cursor>&limit=300
  -> { messages: [...], latestSeq, hasMore }
```

Repeats until `hasMore == false`. Incoming messages are idempotent by `uuid`, so
a message that arrives twice (socket + sync race) is merged, not duplicated.
Cold start with the radio off reads only from Hive and shows history instantly.

## 4. Wi-Fi ↔ mobile data

This is the part most self-hosted apps get wrong. Friend Chat never asks the user
to pick a server; it keeps a set of addresses that all point at the same machine:

| Kind | Example | Reachable when |
| --- | --- | --- |
| `loopback` | `http://127.0.0.1:8787` | desktop dev |
| `lan` | `http://192.168.1.40:8787` | at home, on Wi-Fi |
| `tailnet` | `http://100.88.4.12:8787` | anywhere, via Tailscale |
| `public` | `https://chat.example.com` | anywhere, via VPS/port-forward |

`ConnectionManager` probes every candidate in parallel (`GET /api/health`, 3 s
timeout), sorts by (kind weight, RTT) and keeps the winner. It re-runs on:

* `connectivity_plus` network change (Wi-Fi ↔ cellular)
* a socket error or failed ping
* a 45 s watchdog if nothing is reachable
* any edit to the address list

When the winner changes, `AppSession` rebuilds the `ApiClient` base URL and
reconnects the socket. The `seq` cursor makes the handoff invisible: the message
sent mid-switch is re-sent with the same `clientId` and deduplicated server-side.

LAN is preferred when reachable because it is the fastest and never leaves the
house. The moment you walk out of range those probes fail and the public address
wins — that is the whole switching mechanism.

## 5. Local storage

Two encrypted Hive boxes plus a small integer index:

| Box | Contents |
| --- | --- |
| `fc_messages_v1` | `ChatMessage` maps keyed by uuid (decrypted text cached) |
| `fc_meta_v1` | cursor, session hints, business docs, label selection |
| `fc_seq_v1` | seq → 0, used to compute the cursor quickly |

The AES key is 32 random bytes generated on first run and stored in
`flutter_secure_storage` (Android Keystore / Windows DPAPI / Keychain). Losing
the device loses the key, which is the point.

## 6. Background execution

| Platform | Behaviour |
| --- | --- |
| Android | `flutter_foreground_task` runs a `dataSync` foreground service with a wake lock + Wi-Fi lock. The service isolate keeps the process alive so the main-isolate socket stays connected. Incoming messages become local notifications. |
| Windows | The app keeps its socket while minimised. Closing the window exits. |
| iOS | The OS suspends background sockets. There is no supported workaround without APNs, so the app syncs on open. Documented honestly in `PLATFORM_SETUP.md`. |

Notification path: socket packet → `ChatController` → `AppLifecycleState` check →
`flutter_local_notifications`. Nothing touches Google or Apple.

## 7. Business tooling

| Feature | Storage | Why |
| --- | --- | --- |
| Quick replies | `business_docs` (`quick_replies`) | used by the composer, synced across your own devices |
| Greeting / away | `business_docs` (`auto_reply`) + device clock | the *text* is composed on-device; only settings are stored |
| Catalog | `business_docs` (`catalog`) | must be listable by the peer and survivable |
| Labels | `business_docs` (`labels`) | tag names/colours |

Catalog sharing creates a normal `kind: "catalog"` message whose snapshot lives
**inside** the encrypted envelope, so the chat itself stays opaque.

Documents use optimistic concurrency: the client sends the `rev` it edited and a
stale write gets `409` plus the current document, which the app adopts.

## 8. Database schema

See [`server/src/sql/schema.sql`](../server/src/sql/schema.sql) for the commented
source of truth.

```
users ─────────────┐
 id, username,     │        conversations          messages
 display_name,     │         id, kind,              seq (cursor)
 password_hash,    ├──< conversation_members >──<  uuid, conversation_id,
 phone, cc,        │         (conversation, user)    sender_id, client_id,
 phone_verified_at,│                                  kind, envelope,
 is_business,      │                                  media_id, reply_to,
 accent_color,     │                                  created_at, delivered_at,
 identity_key      │                                  read_at, deleted_at
                   │                                  UNIQUE(sender, client_id)
                   ├──< otp_challenges (phone, code_hash, attempts, expiry)
                   ├──< media (owner, conversation, size, sha256, path)
                   ├──< business_docs (user, section, payload, rev)
                   ├──< devices (user, name, platform, last_seen)
                   └──< audit_log (local only)
```

Design notes:

* `messages.seq` is `INTEGER PRIMARY KEY AUTOINCREMENT` — the sync cursor must
  never be reused, and SQLite guarantees monotonic rowids here.
* `UNIQUE(sender_id, client_id)` is the idempotency guarantee for retries.
* `deleted_at` tombstones a row and blanks the envelope, so "delete for
  everyone" actually removes the ciphertext from your disk.
* `identity_key` holds a public key only. Private keys never leave the device.
* `audit_log` is for you: logins, OTP requests, key changes.

## 9. Module responsibilities (Dart)

| File | Owns | Must not |
| --- | --- | --- |
| `state/app_session.dart` | token, secure storage, endpoints, socket lifecycle | render UI |
| `state/chat_controller.dart` | message list, send/decrypt/sync, receipt application | know about widgets |
| `state/business_controller.dart` | catalog/labels/quick replies + rev handling | send messages |
| `data/crypto_service.dart` | keys, envelopes, attachments, safety number | network |
| `data/socket_service.dart` | socket transport + acks | business rules |
| `data/connection_manager.dart` | which address is reachable | auth |
| `data/local_store.dart` | encrypted persistence | network |
| `services/auto_responder.dart` | greeting/away decisions | UI |

## 10. Why these choices

**Socket.io, websocket-only transport.** A raw WebSocket would work; Socket.io
gives rooms, acks and reconnect backoff for free, and the server is 300 lines.
Long-polling is disabled because it behaves badly across cellular handoffs.

**`node:sqlite` instead of Postgres.** Built into Node 22+, no native compile on
a Raspberry Pi, single-file backup, WAL for concurrent reads. Two users will never
outgrow it.

**Two dependencies.** `express` and `socket.io`. A smaller tree is a smaller
attack surface, which matters more than usual for a privacy product.

**Hand-rolled HS256 tokens and scrypt.** Both are `node:crypto` one-liners; the
alternative was a JWT library plus an argon2 native build for the same result.

**`seq` instead of timestamps.** Clocks on two phones disagree. A server-assigned
integer is the only correct ordering primitive here.
