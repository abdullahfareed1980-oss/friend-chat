# Security model

Private messaging is only worth anything if you can say precisely what is
protected and what is not. This document is that statement.

## 1. Threat model

| Adversary | Can they read messages? | Notes |
| --- | --- | --- |
| Someone on your Wi-Fi | No | TLS/WSS + E2EE |
| Your hosting provider / VPS | No | only ciphertext + metadata |
| Someone who steals `data/friend-chat.db` | No | envelopes are encrypted with keys held on the devices |
| Someone who steals a phone **and** unlocks it | Yes, that conversation | the key is in the device keystore |
| Google / Apple / Meta | No | no FCM, no APNs, no analytics, no crash reporting |
| Your ISP | No (content), yes (that you talk to your server) | metadata |
| A malicious server operator (you) | No, for message bodies | can see who/when/how much, and business metadata |

## 2. What the server can see

Deliberately visible, because a server cannot route what it cannot index:

* account identity: phone number, display name, business name, accent colour
* timing and size of every message, sender, and the `seq` order
* the existence of attachments, their byte size and SHA-256
* business documents: catalog items, prices, label names, quick-reply texts
* your public identity key (a public key, by definition)
* device names ("Pixel 8", "DESKTOP-4F2")

Deliberately invisible:

* every message body, including catalog cards shared in chat
* attachment content, MIME type, file name, dimensions
* auto-reply text actually sent
* the decrypted plaintext of anything in a `messages` row

## 3. The envelope

```
base64( JSON{
  v:   1,
  alg: "x25519-aesgcm",
  from: "<sender user id>",
  epk:  "<base64 ephemeral X25519 public key>",
  n:    "<base64 12-byte AES-GCM nonce>",
  ct:   "<base64 ciphertext||tag>"
} )
```

Send path (in `app/lib/data/crypto_service.dart`):

```
ephemeral = X25519.newKeyPair()
shared    = X25519(ephemeral.private, recipient.identityPublic)
key       = HKDF-SHA256(shared, salt="friend-chat/v1/<conversationId>",
                        info="<senderId>-><recipientId>", 32 bytes)
ct, tag   = AES-256-GCM(key, nonce, plaintext)
```

Properties:

* **Confidentiality + integrity**: AES-GCM, 96-bit random nonce per message.
* **Direction binding**: HKDF `info` includes sender→recipient, so a ciphertext
  cannot be reflected back at the sender.
* **Conversation binding**: the salt includes the conversation id, so a blob
  cannot be replayed into another conversation.
* **Freshness per message**: a new ephemeral key pair per message means
  ciphertexts are not linkable by key material.

Attachments are encrypted separately with a random AES-256 key that travels
*inside* the envelope (`media.keyBase64`), so the blob on disk is useless on its
own, and only the two devices ever hold the key.

## 4. Known limitations (read these)

**a. No forward secrecy / no ratchet.** The recipient's long-term key is reused,
so an attacker who obtains a phone's private key later can decrypt messages that
were already delivered to it. A Double Ratchet (Signal) or MLS fixes this and
costs a session store, skipped-key handling and about 3× the code. This build
chooses auditability; the upgrade path is a drop-in change to
`CryptoService` because the envelope is versioned (`v: 1`).

**b. Multi-device.** Each install generates its own identity key. That means
your *other* device cannot decrypt messages you sent from this one — it shows
"Sent from another device". Correct and safe, but a real limitation. Fixing it
properly means per-recipient-device envelopes: one message encrypted once per
device, with a device registry on the server.

**c. Metadata.** The server knows the two of you talk, how often, and how much.
Padding messages to buckets would hide sizes; it is not implemented.

**d. OTP delivery is physical.** The code appears in your server terminal. If
you cannot see that terminal and cannot SSH in, you cannot sign in. That is the
price of not handing your number to an SMS aggregator.

**e. No server-side search.** The server cannot search what it cannot read.
Search is local-device only.

**f. `OTP_DEBUG=true` is a foot-gun.** It returns the code in the API response.
Only ever enable it on a machine nobody else can reach.

## 5. Accounts and session tokens

* Two accounts, enforced by `MAX_USERS=2` and by `phone_not_enrolled`.
* Password fallback uses scrypt (N=16384, r=8, p=1) with a per-user salt.
* Session tokens are HS256 JWTs with `iss`, `iat`, `exp` (30 days by default) and
  are verified with a constant-time comparison.
* `JWT_SECRET` is auto-generated at `data/jwt.secret` (mode 0600) if unset.
  Rotating it signs everyone out.
* Login and OTP endpoints are rate limited in memory: 12 login attempts / 15 min,
  8 codes / hour per number, 60 s between codes.
* OTP codes are never stored. `otp_challenges.code_hash` is
  `HMAC-SHA256(jwtSecret, "friend-chat-otp:<challengeId>:<code>")`, valid once,
  dead after 10 minutes, capped at 5 attempts.

## 6. Device-side storage

* Hive boxes are encrypted with AES-256 using a 32-byte key generated on first
  run and kept in the platform keystore (`flutter_secure_storage`): Android
  Keystore, Windows DPAPI, iOS/macOS Keychain.
* The X25519 private key is stored there too, base64, never exported.
* Sign out without wiping keeps the cache; "reset this device" clears both keys
  and boxes and the account must re-enrol.

## 7. Hardening checklist

- [ ] `OTP_DEBUG=false` on anything reachable
- [ ] `ALLOW_REGISTRATION=false` (you only need the two seeded accounts)
- [ ] Both seed passwords ≥ 12 characters, not reused
- [ ] TLS in front of port 8787 (Caddy or Tailscale), or LAN + Tailscale only
- [ ] `data/` on disk you control, excluded from any cloud sync folder
- [ ] Backups encrypted (`VACUUM INTO` + `age`/`gpg`)
- [ ] Compare the **safety number** in Settings between both devices once, in
      person, after the second phone enrols
- [ ] `ufw` allows 8787 only from the LAN and tailnet
- [ ] Phone screen lock enabled (it protects the keystore)

## 8. If something goes wrong

| Situation | Do this |
| --- | --- |
| Server disk stolen | Nothing to decrypt. Rotate `JWT_SECRET`, notify the peer. |
| Phone lost | `npm run seed -- --rotate` to change passwords, rotate `JWT_SECRET` (forces all devices out), re-enrol the new phone |
| Key-substitution suspicion | Compare safety numbers in person; if they differ, reset the identity on both devices and re-verify |
| Someone got the server's shell | Assume metadata is known. Ciphertext keeps message bodies private, but delete the OTP/debug config and rotate secrets. |

## 9. What this design does not claim

It does not claim Signal-grade cryptography, anonymity from your network, or
protection against a compromised phone. It claims: your messages are unreadable
to the machine that stores them, no third party is involved in delivery, and the
whole system is small enough that you can read every line that touches a key.
