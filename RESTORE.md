# Disaster recovery / replication

How to rebuild the `edge-proxy` LXC (public TLS reverse proxy for
`compagnie-lily.org`) from this repo on a bare Debian 12 host.

Target end state: Caddy v2 serving the 12 `homeN.compagnie-lily.org` sites in
`caddy/Caddyfile`, plus the cron-driven DNS updater keeping the public A records
pointed at the current home WAN IP. See `CLAUDE.md` for the full operational
picture and the *why* behind each piece.

## Prerequisites

- Debian 12 LXC on the `192.168.45.0/24` LAN, reachable at `192.168.45.37`
  (upstreams are addressed by LAN IP, so the address matters).
- Home-router port-forwards **80 and 443 → 192.168.45.37**.
- The `homeN` A records must already exist in the o2switch zone (the updater
  only *refreshes* existing records — see `CLAUDE.md` → "Public DNS state").
- cPanel API token for the o2switch account (for the DNS updater).

## 1. Install Caddy (Cloudsmith stable apt repo)

```bash
apt-get install -y debian-keyring debian-archive-keyring apt-transport-https curl
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
  | gpg --dearmor -o /usr/share/keyrings/caddy-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
  | tee /etc/apt/sources.list.d/caddy-stable.list
apt-get update && apt-get install -y caddy
```

This creates the `caddy` user/group and installs the stock systemd unit
(`caddy/caddy.service` here is an unmodified snapshot for reference/diff — you
do **not** normally copy it). If `apt-get update` later fails with
`EXPKEYSIG ABA1F9B8875A6661`, re-fetch the gpg.key (same command above) — the
Cloudsmith signing key rotates.

## 2. Drop in the Caddyfile

```bash
install -d -o caddy -g caddy /var/log/caddy       # log dir, owned by caddy
cp caddy/Caddyfile /etc/caddy/Caddyfile

# Validate as the caddy user — validating as root pre-creates the per-site
# log files root:root 0600 and the daemon then can't open them (see CLAUDE.md).
sudo -u caddy caddy validate --config /etc/caddy/Caddyfile
systemctl enable --now caddy
systemctl status caddy --no-pager
```

Caddy will now request certs for all 12 sites via ACME (Let's Encrypt →
ZeroSSL fallback). This only succeeds once DNS + port-forwards are correct.

## 3. Install the DNS updater

```bash
cp .cpanel-api.env.example .cpanel-api.env && chmod 600 .cpanel-api.env
$EDITOR .cpanel-api.env                          # fill in host/user/token

bash cpanel-api.sh Variables/get_user_information | jq .status   # auth check
bash update-77d-records.sh                       # dry run
bash update-77d-records.sh --apply               # real run

# Install the cron entry (every 5 min):
crontab -l 2>/dev/null | grep -qF update-77d-records.sh || \
  (crontab -l 2>/dev/null; grep -v '^#' crontab.root) | crontab -
```

Log: `/var/log/77d-updater.log`.

## 3b. Enable the Caddyfile sync hook (optional but recommended)

```bash
git config core.hooksPath hooks
```

`hooks/pre-commit` then re-syncs `caddy/Caddyfile` from the live
`/etc/caddy/Caddyfile` on every commit, so the snapshot can't drift. It's a
no-op on any host where the live file is absent. (Git doesn't enable committed
hooks automatically — this one line per clone is required.)

## 4. Verify

```bash
systemctl status caddy --no-pager
curl -sS http://127.0.0.1:2019/config/apps/http/servers/srv0/routes | jq '.[].match[].host'
for h in home home2 home3 home4 home6 home7 home8 home9 home10 home11 home12; do
  curl -sS -o /dev/null -w "%{http_code} $h\n" https://$h.compagnie-lily.org/healthz
done
crontab -l | grep update-77d
```

## What this repo does NOT restore

- **The upstream services themselves** — Matrix/Synapse (`home6`), the apps on
  `192.168.45.20`, etc. This host is only the edge proxy; restoring it makes the
  proxy healthy but each backend must be brought up separately.
- **Issued certificates** — not backed up. Caddy re-requests them on first run;
  no action needed as long as DNS + ports are correct (mind Let's Encrypt rate
  limits if you rebuild repeatedly — the ZeroSSL fallback covers overflow).
- **`.cpanel-api.env`** — secret, git-ignored. Recreate from the example.
