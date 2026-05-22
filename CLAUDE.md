# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this host is

LXC container `edge-proxy` (Debian 12, Caddy v2.10.2) acting as the public TLS reverse proxy for the `compagnie-lily.org` homelab. Public DNS chain: `homeN.compagnie-lily.org` → **A records pointing at the current home WAN IP** → this LXC at `192.168.45.37`. The A records are refreshed by a cron-driven updater (see "Public DNS state" below). All upstream services live on the same `192.168.45.0/24` LAN.

The working directory `/root/caddy-manager/` holds the operational scripts (cPanel API wrapper, DNS updater) and is the local checkout of the private GitHub repo `thenemal/77d-caddy-manager`. The Caddy *configuration* still lives at `/etc/caddy/Caddyfile` and is not in this repo.

## The actual config lives outside this directory

- **Live config**: `/etc/caddy/Caddyfile` (single file, no `import` of external files)
- **Service**: `systemd` unit `caddy.service` (runs as user `caddy`, `ExecStart` = `caddy run --environ --config /etc/caddy/Caddyfile`)
- **Logs**: `/var/log/caddy/<site>-access.log` (JSON, rotated `.gz`)
- **Admin API**: `127.0.0.1:2019` (loopback only)
- **ACME email**: `seb45@duck.com` (set in global block)

## Edit / reload workflow

Always validate before reloading — a bad Caddyfile takes the proxy down for every site:

```bash
caddy fmt   --overwrite /etc/caddy/Caddyfile          # normalize whitespace
sudo -u caddy caddy validate --config /etc/caddy/Caddyfile   # parse + adapt check
systemctl reload caddy                                # graceful, zero-downtime
systemctl status caddy --no-pager                     # confirm
journalctl -u caddy -n 50 --no-pager                  # recent errors
```

Use `reload` (not `restart`) for config changes — it preserves in-flight connections and the ACME state. Only `restart` if Caddy itself is wedged.

**Trap when adding a new `log { output file ... }` path**: running `caddy validate` (or any caddy CLI that adapts the config) **as root** will pre-create the referenced log file owned `root:root 0600`, after which the live daemon (running as user `caddy`) cannot open it and the next reload fails with `permission denied`. Either run the validate as `sudo -u caddy ...` (as shown above), or pre-create the file: `install -o caddy -g caddy -m 600 /dev/null /var/log/caddy/<new>.log`. If you already tripped this, `chown caddy:caddy` the file then push the config via the admin API: `caddy reload --config /etc/caddy/Caddyfile --address 127.0.0.1:2019` (bypasses any stuck systemd reload state).

## Caddyfile conventions in use

- **Global HTTP→HTTPS redirect**: the `http://` block 308-redirects everything; do not add per-site `:80` listeners.
- **Two reusable snippets** defined at the top:
  - `(handle-security)` — HSTS + standard hardening headers + `encode zstd gzip`
  - `(block-robots)` — serves `Disallow: /` at `/robots.txt`
  
  New public sites should `import handle-security` and (unless the upstream needs to be indexed) `import block-robots`.
- **Per-site health probe**: most sites expose `respond /healthz 200` for external uptime checks — keep this pattern when adding sites.
- **Per-site access log**: `output file /var/log/caddy/<site>-access.log` in JSON format. Each site gets its own log file; do not share log paths between sites (the Caddyfile currently has duplicates — see below).
- **Naming**: subdomains follow `homeN.compagnie-lily.org` for general services. Don't reuse a slot — pick the next free `homeN`.
- **Upstream**: `reverse_proxy <LAN-IP>:<port>` against `192.168.45.x`. Hostnames are not used for upstreams.

## Special-case sites

- **`home6.compagnie-lily.org`** is a Matrix (Synapse) homeserver. It serves `/.well-known/matrix/{client,server}` directly from Caddy and only proxies `/_matrix/*` and `/_synapse/*` to `192.168.45.20:8008`. It deliberately does **not** import the standard snippets — preserve that if editing.
- **`home8` + `files.home8`** are paired (app + S3/MinIO-style files endpoint on the same backend host `192.168.45.20`).
- **`home9`** is the only site behind Caddy `basic_auth` (single user `seb`, bcrypt hash inline). Preserve the auth block when editing — the upstream (`192.168.45.20:9090`) has no auth of its own.

## Cosmetic note

The `home6` block has a leading space before the site address. Caddyfile tolerates it, but `caddy fmt` will rewrite it — expect a diff.

## Public DNS state

Since 2026-05-12, `homeN.compagnie-lily.org` records are **direct A records** pointing at the current home WAN IP (was CNAMEs to `77d.ddns.net` before). The cron-driven updater on this LXC keeps them in sync:

- Script: `/root/caddy-manager/update-77d-records.sh` (also in the repo)
- Cadence: every 5 min via root crontab; record TTL is 300s to match
- IP discovery: still reads `77d.ddns.net` (No-IP DDNS) via 1.1.1.1, then writes the A records via the cPanel UAPI. Issue #1 tracks removing No-IP from this chain.
- Log: `/var/log/77d-updater.log`

For a new subdomain to obtain a cert:

1. **Create** the `homeN` A record in the zone — either via the cPanel Zone Editor, or via API: `DNS/mass_edit_zone` with `add={"dname":"homeN","record_type":"A","ttl":300,"data":["<current-WAN-IP>"]}`. The updater script only **refreshes existing** records — extending `NAMES` alone will not create a new record (it logs `no record for X in zone, skipping`).
2. Append the new name to `NAMES` in `update-77d-records.sh` so subsequent WAN-IP changes are picked up.
3. Confirm ports 80/443 are forwarded to `192.168.45.37` on the home WAN.
4. Add the site block to `/etc/caddy/Caddyfile` and reload Caddy.

Caddy's ACME setup uses **Let's Encrypt as the primary issuer with automatic fallback to ZeroSSL** (HTTP-01 and TLS-ALPN-01 challenges). Cert + key storage:

```
/var/lib/caddy/.local/share/caddy/certificates/
  acme-v02.api.letsencrypt.org-directory/<name>/...
  acme.zerossl.com-v2-dv90/<name>/...
```

The presence of a `zerossl` directory for a given name is a tell that Let's Encrypt issuance failed at some point and the fallback succeeded — worth investigating before renewal.

## Known DNS issue (o2switch zone)

Between 2026-05-09 and 2026-05-11 the authoritative NS `ns1/ns2.o2switch.net` regressed: they now SERVFAIL on `A` and `CAA` queries for any name whose CNAME points outside the zone. Every `homeN.compagnie-lily.org` previously CNAME'd to `77d.ddns.net.` and so all of them broke. The names still answer correctly when queried specifically for `CNAME` type. Apex records and in-zone-target CNAMEs (e.g. `www` → apex) are unaffected.

**This is worked around** by replacing the CNAMEs with direct A records (see "Public DNS state" above). With no CNAME to chase, the buggy code path is never hit. A support ticket is open with o2switch; the workaround stays in place until/unless they confirm a fix.

Verify the regression (or its resolution):

```bash
dig @ns1.o2switch.net home5.compagnie-lily.org A     +norecurse  # should be NOERROR now
dig @ns1.o2switch.net home5.compagnie-lily.org CAA   +norecurse  # should be NOERROR now
```

If/when o2switch confirms a fix: stop the cron, then either edit each `homeN` back to a CNAME via cPanel Zone Editor, or via API (`DNS/mass_edit_zone` with `record_type:"CNAME"`, `data:["77d.ddns.net."]`).

## o2switch cPanel API (DNS management)

The registrar's cPanel exposes a UAPI at `https://beluga.o2switch.net:2083`. A wrapper script and credentials live alongside this file:

- **Wrapper**: `/root/caddy-manager/cpanel-api.sh` — usage: `bash cpanel-api.sh <Module>/<function> [query]`
- **Creds**: `/root/caddy-manager/.cpanel-api.env` (mode 600 — keep it that way; out of any git history)

The DNS module is the modern **`DNS/*`** (not the legacy `ZoneEdit/*`). Record values come back base64-encoded in `dname_b64` / `data_b64` — decode with `base64 -d`. Examples:

```bash
bash cpanel-api.sh Variables/get_user_information               # auth check
bash cpanel-api.sh DNS/parse_zone "zone=compagnie-lily.org"     # full zone (43 records)
bash cpanel-api.sh DNS/mass_edit_zone "zone=...&serial=...&..." # edits — needs current serial
bash cpanel-api.sh Tokens/list                                   # API token metadata
```

`DNS/mass_edit_zone` takes `zone=`, `serial=` (current SOA serial — wrong serial is rejected, preventing concurrent-edit races), and one or more `edit={"line_index":N,"dname":"<label>","record_type":"...","ttl":N,"data":[...]}` parameters. The URL-encoding of the `edit=` JSON is finicky — see `test-dns-edit.sh` and `update-77d-records.sh` for the pattern (`jq -nc` to build, `jq -sRr @uri` to encode). Both auth NS pick up edits within ~30s for in-place edits.

`feature.dnssec: "0"` on this `subaccount_pro` plan: DNSSEC is not available on this account, so don't go looking for a DNSSEC pane as the cause of zone weirdness.

**Token rotation**: `Tokens/revoke` matches by `name=` and removes **every** token sharing that name. Always create the new token with a *distinct* name (e.g. add a `-v2` or date suffix), verify it works, then revoke the old name explicitly. Reusing the name during overlap will revoke the token you just started using.

## Inspecting live state

The systemd unit reads from disk, but the running daemon may be on a stale config if a reload was rejected. To see what's actually loaded:

```bash
curl -sS http://127.0.0.1:2019/config/ | jq                 # full live JSON config
curl -sS http://127.0.0.1:2019/config/apps/http/servers/srv0/routes | jq '.[].match[].host'  # all live hostnames
journalctl -u caddy --since "10 minutes ago" | grep -iE 'acme|tls.issuance|challenge|error'  # cert + error activity
```

For ACME-related debugging, watch for `"challenge failed"` and `"could not get certificate from issuer"` lines — they include the issuer URL and the LE/ZeroSSL error detail.
