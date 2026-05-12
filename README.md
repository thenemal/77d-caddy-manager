# 77d-caddy-manager

Operational scripts for the `compagnie-lily.org` edge-proxy LXC.

This LXC runs Caddy as the public TLS reverse proxy for `homeN.compagnie-lily.org`
homelab services. Public DNS chain:

    homeN.compagnie-lily.org → A record (refreshed by cron) → home WAN → this LXC

The A records are kept in sync with the current home WAN IP by
`update-77d-records.sh`, running on this LXC via root cron.

See `CLAUDE.md` for the full operational picture (Caddyfile conventions,
ACME setup, the o2switch DNS regression that drove this workaround).

## Status

- **Live since 2026-05-12.** All `homeN` records are direct A records, cron
  refresh runs every 5 minutes.
- **Open improvement**: drop the No-IP DDNS middleman and detect the WAN IP
  directly via an HTTP echo service. Tracked in [#1](https://github.com/thenemal/77d-caddy-manager/issues/1).

## Contents

| File | Purpose |
|---|---|
| `CLAUDE.md` | Project context for Claude Code (and humans). |
| `cpanel-api.sh` | Thin wrapper around o2switch cPanel UAPI. |
| `test-dns-edit.sh` | One-shot smoke test of the write path (changes `home5` TTL only). |
| `update-77d-records.sh` | The main updater — flips/refreshes `homeN` A records to the current WAN IP. |
| `.cpanel-api.env` | **Not committed.** Holds cPanel host/user/token. Create from `.cpanel-api.env.example`. |

## Why this exists

Between 2026-05-09 and 2026-05-11, o2switch's authoritative nameservers
(`ns1`/`ns2.o2switch.net`) regressed: they now `SERVFAIL` on `A` and `CAA`
queries for any subdomain whose `CNAME` target is out-of-bailiwick. Every
`homeN.compagnie-lily.org` chases to `77d.ddns.net.`, so all of them broke.
The same names still answer correctly when queried specifically for `CNAME`.

A support ticket is open with o2switch, but the inconclusive reply suggests
a fix may take a while. The workaround implemented here: replace the
`CNAME → 77d.ddns.net` records with **direct `A` records** pointing at the
current home WAN IP. With no CNAME to chase, the buggy auth-server code
path is never triggered.

The home WAN IP is dynamic (Verizon DHCP), so a small updater script polls
77d.ddns.net (resolved via a non-o2switch resolver) and pushes any IP change
into the cPanel zone via UAPI.

## Setup

```bash
# 1. Copy creds template and fill in
cp .cpanel-api.env.example .cpanel-api.env
chmod 600 .cpanel-api.env
$EDITOR .cpanel-api.env

# 2. Smoke test API access
bash cpanel-api.sh Variables/get_user_information | jq .status

# 3. Smoke test write path (changes home5 TTL only, easy revert)
bash test-dns-edit.sh

# 4. Dry-run the updater
bash update-77d-records.sh

# 5. First real run — converts all homeN CNAMEs to A records
bash update-77d-records.sh --apply
```

## Cron

The cron entry is installed in root's crontab on the edge-proxy LXC:

```cron
*/5 * * * * /root/caddy-manager/update-77d-records.sh --apply >> /var/log/77d-updater.log 2>&1
```

5-minute cadence matches the 300s TTL on the records. If the WAN IP changes,
clients pick up the new value within 5–10 minutes. The script is idempotent
and exits cheaply when nothing has changed, so the cadence is harmless.

Log: `/var/log/77d-updater.log` on the LXC. Tail it to confirm refresh
behavior after a WAN IP change.

## Reverting to CNAMEs

If/when o2switch fixes the regression, recreate the CNAMEs via cPanel
Zone Editor (or via API: `DNS/mass_edit_zone` with `record_type:"CNAME"`,
`data:["77d.ddns.net."]`). Stop the cron job before doing so or the updater
will fight you.
