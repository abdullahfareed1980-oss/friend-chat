# Friend Chat

A private, self-hosted, real-time messenger for **exactly two people** — a phone
and a PC, a couple, two friends, or you and a business contact — with no cloud in
the middle. It looks and behaves like WhatsApp / WhatsApp Business, but every
byte of state lives on a server **you** own, and message bodies are end-to-end
encrypted so even that server cannot read them.

```
┌──────────────┐        wss://  (end-to-end encrypted)        ┌──────────────┐
│  Android APK │  ────────────────────────────────────────►  │  Windows .exe│
└──────┬───────┘                                             └──────┬───────┘
       │                                                            │
       └──────────────►  Friend Chat Server  ◄─────────────────────┘
                        (Node + Socket.io + SQLite, on your Pi/VPS)
                          stores ciphertext + metadata only
```

**Status of what is in this repo**

| Part | State |
| --- | --- |
| `server/` — Node 22+ / Socket.io / SQLite | complete, **14 end-to-end tests passing** |
| `app/` — Flutter (Android, Windows, iOS source-compatible) | complete, **`flutter analyze` clean** |
| Onboarding (welcome → server → phone → OTP) | implemented |
| Chat, ticks, offline cache, background service, business tools | implemented |
| Docs (architecture, API, deployment, security, build) | included |

What is *not* here: a signed APK or a compiled `.exe`. Pushing a `v*` tag makes
GitHub Actions build and attach both ([`.github/workflows/build.yml`](../.github/workflows/build.yml));
locally they are one command away — see [docs/BUILD.md](docs/BUILD.md) — but they
must be built on a machine with the Android SDK / Windows toolchain, which a
headless container does not have. No part of the app was run on a device yet; the analyse pass proves it
compiles, not that it looks right on your screen.

---

## The look

Midnight base, electric indigo primary, soft mint for "alive" states. Every
colour is defined once, in
[`app/lib/theme/friend_chat_theme.dart`](app/lib/theme/friend_chat_theme.dart).

| Token | Hex | Used for |
| --- | --- | --- |
| Midnight | `#0B0B14` | app background |
| Night | `#10101B` | sheets, dialogs |
| Surface | `#161624` | cards |
| Indigo | `#6366F1` | primary accent |
| Indigo deep | `#4F46E5` | buttons, outgoing bubble |
| Violet | `#8B5CF6` | gradient partner |
| Mint | `#34D399` | online, delivered/read ticks, "secure" |
| Mint soft | `#6EE7B7` | gradient partner for mint |
| Danger | `#FB7185` | errors |

The logo (overlapping speech bubbles on a shield with a secure node network)
exists twice, deliberately: as a vector master
([`assets/logo/friend_chat_logo.svg`](app/assets/logo/friend_chat_logo.svg))
and as a `CustomPainter`
([`lib/widgets/friend_chat_logo.dart`](app/lib/widgets/friend_chat_logo.dart))
so the app bar mark is crisp at 24 px with no asset decode. The painter and the
SVG draw the same geometry.

---

## Directory layout

```
friend-chat/
├── README.md                     ← you are here
├── docs/
│   ├── ARCHITECTURE.md           how the pieces fit, with data-flow diagrams
│   ├── API.md                    every REST endpoint and socket event
│   ├── BUILD.md                  Android APK + Windows .exe, step by step
│   ├── DEPLOYMENT.md             Raspberry Pi, VPS, Tailscale, systemd, backups
│   ├── PLATFORM_SETUP.md         manifest / gradle / desktop scaffolding
│   └── SECURITY.md               threat model, envelope format, known limits
│
├── server/                       "Friend Chat Server"
│   ├── package.json              2 runtime deps: express + socket.io
│   ├── .env.example              every knob, documented
│   ├── Dockerfile                node:24-alpine, non-root, healthcheck
│   ├── docker-compose.yml        server + Caddy (automatic TLS)
│   ├── Caddyfile                 wss:// termination
│   ├── src/
│   │   ├── index.js              entry point, prints LAN URLs to pair with
│   │   ├── server.js             express + socket.io + sqlite wiring
│   │   ├── config.js             env loading, secret generation
│   │   ├── db.js                 data layer, additive migrations
│   │   ├── auth.js               scrypt, HS256 tokens, login throttle
│   │   ├── phone.js              E.164 normalisation
│   │   ├── routes.js             REST: OTP, sync, media, business docs
│   │   ├── realtime.js           socket: send, receipts, presence, typing
│   │   ├── seed.js               enrols the two accounts + conversation
│   │   └── sql/schema.sql        the database schema, commented
│   └── test/server.test.mjs      14 end-to-end tests
│
└── app/                          "Friend Chat" (Flutter)
    ├── pubspec.yaml
    ├── assets/logo/friend_chat_logo.svg
    ├── platform/android/                    manifest, network policy, gradle overlay
    ├── tools/prepare_platform.sh            generates android/ + windows/ (CI uses it)
    ├── windows/installer/friend-chat.iss    Inno Setup → single .exe
    └── lib/
        ├── main.dart             startup order
        ├── app.dart              theme, session gate, controller ownership
        ├── data/
        │   ├── connection_manager.dart   races LAN / tailnet / public
        │   ├── crypto_service.dart       X25519 + AES-256-GCM
        │   ├── local_store.dart          encrypted Hive cache + seq cursor
        │   ├── rest_client.dart          REST calls
        │   └── socket_service.dart       typed socket events and acks
        ├── models/models.dart    messages, users, catalog, labels, endpoints
        ├── screens/
        │   ├── welcome_screen.dart        first launch
        │   ├── server_setup_screen.dart   which server am I talking to?
        │   ├── phone_screen.dart          country code + number
        │   ├── otp_screen.dart            6-digit verification
        │   ├── chat_list_screen.dart      home
        │   ├── chat_screen.dart           the conversation
        │   ├── business_hub_screen.dart   WhatsApp Business corner
        │   ├── quick_replies_screen.dart
        │   ├── auto_reply_screen.dart     greeting + away + schedule
        │   ├── catalog_screen.dart
        │   ├── labels_screen.dart
        │   └── settings_screen.dart       endpoints, safety number, sign out
        ├── services/
        │   ├── auto_responder.dart       on-device greeting/away logic
        │   ├── background_service.dart   Android foreground service
        │   └── notifications.dart        local notifications, no FCM
        ├── state/
        │   ├── app_session.dart          token, keys, endpoints, socket
        │   ├── chat_controller.dart      send / receive / receipts / sync
        │   └── business_controller.dart  quick replies, catalog, labels
        ├── theme/friend_chat_theme.dart
        └── widgets/                      logo, atoms, bubbles, ticks
```

---

## Quick start

### 1. Server (5 minutes)

```bash
cd server
cp .env.example .env

# Set both passwords (12+ chars) and both phone numbers in .env.
npm install
npm run seed          # creates the two accounts + the shared conversation
npm start
```

The server prints the addresses to pair with:

```
  listening     http://0.0.0.0:8787
  Reachable on this machine / LAN:
    http://127.0.0.1:8787
    http://192.168.1.40:8787   (wlan0)
```

### 2. App

```bash
cd app
flutter create --org com.friendchat --project-name friend_chat /tmp/fc
cp -r /tmp/fc/android /tmp/fc/windows .     # one-time platform scaffolding
flutter pub get
flutter run                                  # or: flutter build apk --release
```

Then in the app: **Welcome → server address → phone number → OTP**.

The OTP is printed by your own server, not sent by SMS:

```
  ┌──────────────────────────────────────────────┐
  │  Friend Chat verification code               │
  │                                              │
  │      4 9 2 8 1 6                             │
  │                                              │
  │  for +62 81234567890                         │
  │  valid for 10 minutes, single use            │
  └──────────────────────────────────────────────┘
```

More: [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md) (Pi, VPS, Tailscale, backups),
[docs/BUILD.md](docs/BUILD.md) (APK + installer).

---

## Feature map

| Requirement | Where it lives |
| --- | --- |
| Real-time one-to-one text | `server/src/realtime.js` ↔ `chat_controller.dart` |
| Media metadata sharing | encrypted upload (`POST /api/media`), descriptor inside the envelope |
| Connection synchronisation | global `seq` cursor + `GET /api/sync` + `sync:request` |
| Sent / delivered / read | `messages.delivered_at` / `read_at`, `StatusTicks` widget |
| Offline history | encrypted Hive boxes, readable with the radio off |
| Wi-Fi ↔ mobile data | `connection_manager.dart` races every saved address |
| Background survival | `flutter_foreground_task` dataSync service on Android |
| Notifications without FCM/APNs | socket → `flutter_local_notifications` |
| Quick replies | `/api/business/quick_replies` + one-tap insertion in the composer |
| Greeting / away messages | on-device `auto_responder.dart` (server has no plaintext) |
| Catalog sharing | `catalog` document + encrypted catalog card messages |
| Chat labels | `labels` document + per-chat selection |
| Phone + OTP onboarding | `phone_screen.dart`, `otp_screen.dart`, `request-otp` / `verify-otp` |

---

## Design decisions worth knowing

**The server stores no plaintext.** A message row is
`{seq, uuid, sender, kind, envelope}` where `envelope` is an opaque base64 blob.
`SELECT * FROM messages` on your own database shows no conversation.

**The OTP comes from your own terminal.** Every alternative (Twilio, Firebase
Auth, WhatsApp's own SMS) hands your phone number and a one-time secret to a
third party, which contradicts the brief. `OTP_DEBUG=true` returns the code in
the API response for LAN testing only.

**The auto-responder runs on the device.** A server that cannot read messages
cannot compose a greeting. The foreground service keeps the app alive so the
reply still goes out.

**Business documents are not encrypted.** A catalog has to be listable by the
peer's app and survive a reinstall, so prices, labels and catalog entries live in
plain tables on your server. Conversation content never does.

**Two users is enforced, not assumed.** `MAX_USERS=2`, one conversation, and an
OTP request for an unenrolled number is rejected with `phone_not_enrolled`.

---

## Verification actually performed

```
$ cd server && npm test
✔ 14 tests passing   (OTP onboarding, receipts, idempotent retry, sync replay,
                      media round-trip, business docs, presence, tombstones)

$ cd app && flutter analyze
No issues found!     (24 Dart files, 115 packages resolved)
```

Not verified: no APK was built, no Windows binary was produced, and the app was
never launched on a device or emulator here. The UI has not been looked at —
the workflow in `.github/workflows/build.yml` is the path to a signed APK and
installer, and it has not been run yet either (it needs a pushed tag).
