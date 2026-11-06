# API reference

Base URL is whatever your server listens on, e.g. `http://192.168.1.40:8787`.
All REST responses are JSON. Authenticated endpoints need
`Authorization: Bearer <token>`. Media endpoints use raw bytes, not JSON.

---

## REST

### `GET /api/health`

Unauthenticated on purpose: the app probes it to decide which address to use.

```json
{
  "ok": true,
  "service": "Friend Chat Server",
  "version": "1.0.0",
  "time": "2026-11-05T09:12:44.120Z",
  "users": 2,
  "maxUsers": 2,
  "registrationOpen": false,
  "otpDelivery": "console",
  "e2ee": true
}
```

### `POST /api/auth/request-otp`

```json
{ "countryCode": "+62", "phone": "812 3456 7890" }
```

200:

```json
{
  "challengeId": "b0f0…",
  "phone": "6281234567890",
  "countryCode": "+62",
  "expiresInSeconds": 600,
  "resendAfterSeconds": 60,
  "delivery": "console",
  "known": true
}
```

`devCode` appears **only** when the server runs with `OTP_DEBUG=true`.

| Status | `error` | Meaning |
| --- | --- | --- |
| 400 | `invalid_country_code` / `invalid_phone` | bad input |
| 403 | `phone_not_enrolled` | number is not one of the two enrolled |
| 429 | `resend_too_soon` | includes `retryAfter` seconds |
| 429 | `too_many_requests` | hourly cap (`OTP_MAX_PER_HOUR`) |

The code is printed on the server's own stdout — the delivery channel is a
terminal only you can read.

### `POST /api/auth/verify-otp`

```json
{
  "challengeId": "b0f0…",
  "code": "492816",
  "device": { "id": "uuid", "name": "Pixel 8", "platform": "android" }
}
```

200: the session object.

```json
{
  "token": "eyJhbGciOiJIUzI1NiIs…",
  "expiresIn": 2592000,
  "user": {
    "id": "…", "username": "hana", "displayName": "Hana",
    "phone": "6281234567890", "countryCode": "+62", "phoneVerified": true,
    "isBusiness": false, "businessName": null,
    "accentColor": "#4F46E5", "identityKey": null,
    "createdAt": "…", "lastSeenAt": "…"
  },
  "peer": { "id": "…", "displayName": "Omar", "identityKey": "…" },
  "conversation": { "id": "…", "kind": "direct", "createdAt": "…" }
}
```

| Status | `error` |
| --- | --- |
| 401 | `invalid_code` (+ `attemptsRemaining`) |
| 404 | `challenge_not_found` |
| 409 | `challenge_used` |
| 410 | `code_expired` |
| 429 | `too_many_attempts` |

### `POST /api/auth/login` (fallback)

```json
{ "username": "hana", "password": "…", "device": { … } }
```

Same session object. Exists for the server owner and for recovery; the app uses
OTP. Throttled to 12 attempts / 15 min / IP.

### `GET /api/me`

Session object for the current token (no `token` field).

### `PUT /api/me/identity`

```json
{ "publicKey": "<base64 X25519 public key>" }
```

Publishes this device's encryption key so the peer can encrypt to it. Emits
`peer:identity` to the peer.

### `GET /api/directory`

```json
{ "peer": { "id": "…", "displayName": "Omar", "identityKey": "…" } }
```

### `POST /api/media`

Raw ciphertext upload.

```
Content-Type: application/octet-stream
X-FC-Media: {"conversationId":"…","sha256":"<sha256 of the body>"}
```

201:

```json
{ "media": { "id": "…", "ownerId": "…", "sizeBytes": 18422, "sha256": "…", "createdAt": "…" } }
```

The server never learns the MIME type, file name or dimensions — those live
inside the encrypted message envelope. A checksum mismatch is `400
checksum_mismatch`.

### `GET /api/media/:id`

Returns `application/octet-stream` (the ciphertext), with `X-FC-Sha256`.
Members of the conversation only; `403` otherwise.

### `DELETE /api/media/:id`

Owner only. Removes the blob and the row.

### `GET /api/sync?since=<seq>&limit=300`

```json
{
  "messages": [ { "seq": 42, "uuid": "…", "conversationId": "…", "senderId": "…",
                  "clientId": "…", "kind": "text", "envelope": "…",
                  "mediaId": null, "replyTo": null, "createdAt": "…",
                  "deliveredAt": "…", "readAt": null, "deletedAt": null } ],
  "media": [],
  "latestSeq": 42,
  "serverTime": "…",
  "hasMore": false
}
```

### Business documents

| Method | Path | Notes |
| --- | --- | --- |
| `GET` | `/api/business` | all four sections for the caller |
| `GET` | `/api/business/:section` | `quick_replies` \| `auto_reply` \| `catalog` \| `labels` |
| `PUT` | `/api/business/:section` | `{ "payload": {…}, "rev": n }` |
| `GET` | `/api/business/peer/catalog` | the peer's catalog, read-only |

`PUT` returns `{ section, payload, rev, updatedAt }`. A stale `rev` gets:

```json
409 { "error": "rev_conflict", "rev": 3, "payload": { … } }
```

---

## Socket.io

Connect with `transports: ["websocket"]` and
`auth: { token: "<bearer>", device: { id, name, platform } }`.
An invalid token fails the handshake with `unauthorized`.

### Server → client

| Event | Payload |
| --- | --- |
| `server:hello` | `{ service, version, user, peer, conversation, peerOnline, serverTime }` |
| `message:new` | a message object (same shape as `/api/sync` items) |
| `message:deleted` | `{ uuid, conversationId, at }` |
| `receipt:update` | `{ conversationId, upToSeq, status: "delivered"\|"read", at, by }` |
| `typing` | `{ conversationId, userId, isTyping, at }` |
| `presence` | `{ userId, online, at }` |
| `peer:identity` | `{ userId, identityKey }` |
| `business:update` | `{ userId, section, payload, rev, updatedAt }` |

### Client → server (all take an ack callback)

| Event | Payload | Ack |
| --- | --- | --- |
| `message:send` | `{ conversationId, clientId, kind, envelope, mediaId?, replyTo? }` | `{ ok, message }`, or `{ ok:true, duplicate:true }` on retry |
| `receipt:delivered` | `{ seqs: [12, 13] }` | `{ ok }` |
| `receipt:read` | `{ conversationId, upToSeq }` | `{ ok }` |
| `typing` | `{ conversationId, isTyping }` | none (fire and forget) |
| `sync:request` | `{ sinceSeq, limit }` | `{ ok, messages, latestSeq, hasMore, serverTime }` |
| `message:delete` | `{ uuid }` | `{ ok }` |
| `presence:ping` | `{}` | `{ ok, at }` |

`message:send` errors come back in the ack as
`{ ok:false, error: "invalid_kind" | "forbidden" | "missing_envelope" |
"envelope_too_large" | "invalid_client_id" }` — never as a socket disconnect, so
the UI can mark a single bubble failed and retry.

### Delivery semantics

* Sending is **at-least-once** from the client and **effectively-once** on the
  server via `UNIQUE(sender_id, client_id)`.
* `message:new` reaches the peer's user room and the sender's *other* devices.
  The sending socket already has the optimistic bubble.
* `receipt:delivered` is emitted by the receiving device only after the row is
  persisted locally, so "delivered" is honest.
* `receipt:read` is aggregate (`upToSeq`), which keeps the traffic tiny and is
  enough for a two-person conversation.
