# Self-hosting Friend Chat Server

Goal: a server only you can reach, that keeps working when your laptop sleeps and
does not depend on anybody's cloud.

There are three good setups. Pick one.

| Setup | Best for | Remote access | Cost |
| --- | --- | --- | --- |
| A. Raspberry Pi / home box + Tailscale | the brief's default | Tailscale | ~€0 |
| B. Home box + port forwarding + Caddy | no extra software on phones | dynamic DNS | ~€0 + domain |
| C. Private VPS + Docker + Caddy | always-on, static IP | built in | ~€4/mo |

---

## A. Raspberry Pi (recommended)

### 1. Install Node

`node:sqlite` needs Node **22.5+**; use 22 LTS or newer.

```bash
# Raspberry Pi OS (64-bit)
curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -
sudo apt-get install -y nodejs
node -v      # v22.x or v24.x
```

### 2. Put the code somewhere stable

```bash
sudo mkdir -p /srv/friend-chat && sudo chown $USER /srv/friend-chat
# copy the repo (git clone, scp, rsync, whatever you prefer)
cd /srv/friend-chat/server
cp .env.example .env
nano .env        # set both passwords and both phone numbers
npm install --omit=dev
npm run seed
```

### 3. Run it as a service

`/etc/systemd/system/friend-chat.service`:

```ini
[Unit]
Description=Friend Chat Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=pi
WorkingDirectory=/srv/friend-chat/server
ExecStart=/usr/bin/node src/index.js
Restart=always
RestartSec=3
Environment=NODE_ENV=production

# Hardening: the server only needs its own directory.
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/srv/friend-chat/server/data

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now friend-chat
sudo systemctl status friend-chat
journalctl -u friend-chat -f          # this is also where your OTP appears
```

### 4. Reach it from outside the house: Tailscale

Port forwarding on a home router is fragile (CGNAT, changing IPs, exposing a
service to the internet). Tailscale gives both phones a private address that
works on Wi-Fi *and* mobile data with no ports open:

```bash
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up
tailscale ip -4        # e.g. 100.88.4.12
```

In the app, add **two** addresses during setup:

```
http://192.168.1.40:8787     ← LAN, fastest at home
http://100.88.4.12:8787      ← Tailscale, works anywhere
```

Install Tailscale on both phones/PCs and sign in to the same tailnet. The app's
endpoint race will prefer LAN at home and switch to the tailnet address when you
leave — you never touch a setting again.

### 5. Firewall

```bash
sudo ufw allow from 192.168.1.0/24 to any port 8787 proto tcp
sudo ufw allow in on tailscale0 to any port 8787 proto tcp
sudo ufw deny 8787
sudo ufw enable
```

If you skip Tailscale, do **not** open 8787 to the internet without TLS in front
of it (option B or C).

---

## B. Home box + port forwarding + Caddy

Only worth it if you cannot install Tailscale on the devices.

1. Get a domain (or a free DDNS hostname) pointing at your public IP.
2. Forward **443** (not 8787) to the Pi.
3. Put Caddy in front so the phone can use `wss://`:

```bash
sudo apt-get install -y caddy
```

`/etc/caddy/Caddyfile` (same content as `server/Caddyfile`):

```
chat.example.com {
    reverse_proxy 127.0.0.1:8787 {
        flush_interval -1
    }
    header {
        Strict-Transport-Security "max-age=31536000; includeSubDomains"
        X-Content-Type-Options "nosniff"
        X-Frame-Options "DENY"
        Referrer-Policy "no-referrer"
        -Server
    }
}
```

`flush_interval -1` disables buffering, which WebSockets need.

Caveats to accept: your home IP is public, the router may get a new WAN IP (use
DDNS), and CGNAT will block this entirely (fall back to Tailscale).

---

## C. Private VPS (Docker Compose)

```bash
git clone <your-repo> friend-chat && cd friend-chat/server
cp .env.example .env && nano .env      # passwords + phone numbers
docker compose run --rm server npm run seed
docker compose up -d
docker compose logs -f server           # OTP codes land here
```

`docker-compose.yml` runs the server (non-root, `/data` volume) plus Caddy with
automatic Let's Encrypt certificates. Only 80/443 are published.

Point the app at `https://chat.example.com`.

---

## Operations

### Where the OTP goes

`OTP_DELIVERY=console`. The code is printed on the server's stdout:

```bash
journalctl -u friend-chat -f          # systemd
docker compose logs -f server          # docker
```

`OTP_DEBUG=true` returns the code in the HTTP response instead — LAN testing
only, never on an internet-reachable instance.

### Backups

The database is one file. Use SQLite's online backup so you never copy a
half-written WAL:

```bash
cd /srv/friend-chat/server
node -e "const {DatabaseSync}=require('node:sqlite'); \
  const db=new DatabaseSync('data/friend-chat.db'); \
  db.exec(\"VACUUM INTO 'data/backup-$(date +%F).db'\");"
rsync -a data/ /mnt/usb/friend-chat-backup/
```

`data/media/*.bin` are ciphertext blobs; back them up too if you want attachments
to survive. They are useless without the phones' keys, which is exactly right.

### Rotating a phone number or password

```bash
nano .env            # update SEED_USER_A_PHONE / SEED_USER_A_PASSWORD
npm run seed -- --rotate
sudo systemctl restart friend-chat
```

Existing sessions stay valid until they expire (`TOKEN_TTL_SECONDS`). To revoke
everything immediately, change `JWT_SECRET` and restart — every device has to
sign in again.

### Updating the server

```bash
cd /srv/friend-chat && git pull
cd server && npm install --omit=dev
sudo systemctl restart friend-chat
```

Schema changes are additive and applied automatically on boot
(`ensureColumns` in `src/db.js`); no migration command to forget.

### Health and logs

```bash
curl -s localhost:8787/api/health | jq
```

Logging is deliberately minimal: method + path + status, no bodies, no query
strings. `audit_log` in SQLite records logins, OTP requests and key changes — it
never leaves the box.

### What a compromise would and would not expose

| Data | On disk |
| --- | --- |
| Message bodies | AES-256-GCM ciphertext, key never sent |
| Attachments | ciphertext blobs |
| Who talked to whom, when, how much | visible (one conversation, two users) |
| Phone numbers, display names | visible (that is the account) |
| Catalog, labels, quick replies | visible (business metadata, not chat) |
| Passwords | scrypt hashes |
| OTP codes | only HMACs, dead after 10 minutes |

See [SECURITY.md](SECURITY.md) for the full threat model.
