#!/usr/bin/env bash
# Sync homeN.compagnie-lily.org A records to the current home WAN IP.
#
# Resolves 77d.ddns.net (via a public resolver, NOT o2switch) to find the
# current WAN IP, then ensures every homeN.compagnie-lily.org is a direct A
# record pointing there. Works around the o2switch authoritative-NS bug that
# SERVFAILs on out-of-bailiwick CNAME chasing.
#
# Scope: this script only REFRESHES existing records. Names in $NAMES that
# don't yet exist in the zone are skipped with a WARN ("no record for X in
# zone, skipping"). To onboard a new subdomain, first create the A record
# (cPanel Zone Editor, or `DNS/mass_edit_zone` with an `add=` parameter),
# then extend $NAMES so future runs keep it in sync.
#
# Idempotent: only emits edits for records whose type or value differs.
# Default mode is dry-run; pass --apply to actually push to cPanel.
set -euo pipefail

ZONE="compagnie-lily.org"
DDNS_SOURCE="77d.ddns.net"
PUBLIC_RESOLVER="1.1.1.1"
TTL=300
NAMES=(home home2 home3 home4 home5 home6 home7 home8 home9 home10 home11 home12)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WRAPPER="${SCRIPT_DIR}/cpanel-api.sh"

log() { printf '%s [%-5s] %s\n' "$(date -Iseconds)" "$1" "$2"; }

require_cmd() {
    command -v "$1" >/dev/null || { log ERROR "missing required command: $1"; exit 1; }
}
require_cmd dig
require_cmd jq
require_cmd curl
[ -x "$WRAPPER" ] || [ -r "$WRAPPER" ] || { log ERROR "wrapper not found: $WRAPPER"; exit 1; }

# 1. Resolve current WAN IP. Pick an authoritative resolver that isn't o2switch
#    — we're routing around their broken auth NS, so don't trust them here either.
TARGET_IP=$(dig +short "$DDNS_SOURCE" A @"$PUBLIC_RESOLVER" | tail -1)

if ! [[ "$TARGET_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    log ERROR "could not resolve $DDNS_SOURCE via $PUBLIC_RESOLVER (got: '${TARGET_IP:-empty}')"
    exit 1
fi
case "$TARGET_IP" in
    0.0.0.0|127.*|10.*|192.168.*|169.254.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*)
        log ERROR "refusing to push non-public IP: $TARGET_IP"
        exit 1
        ;;
esac

log INFO "$DDNS_SOURCE resolves to $TARGET_IP"

# 2. Fetch zone snapshot + current SOA serial in one call
zone_json=$(bash "$WRAPPER" DNS/parse_zone "zone=${ZONE}")
if ! echo "$zone_json" | jq -e '.status == 1' >/dev/null; then
    log ERROR "parse_zone failed: $(echo "$zone_json" | jq -c '.errors // .')"
    exit 1
fi
serial=$(echo "$zone_json" | jq -r '.data[] | select(.record_type=="SOA") | .data_b64[2] | @base64d')
log INFO "zone serial: $serial"

# 3. Build edit list — one entry per homeN that needs a change
declare -a edit_params=()
declare -a changed=()

for name in "${NAMES[@]}"; do
    rec=$(echo "$zone_json" \
        | jq --arg n "$name" -c '[.data[] | select((.dname_b64 | @base64d) == $n)] | .[0]')
    if [ "$rec" = "null" ]; then
        log WARN "no record for '$name' in zone, skipping"
        continue
    fi
    li=$(echo "$rec" | jq -r '.line_index')
    rtype=$(echo "$rec" | jq -r '.record_type')
    cur=$(echo "$rec" | jq -r '.data_b64[0] | @base64d')

    if [ "$rtype" = "A" ] && [ "$cur" = "$TARGET_IP" ]; then
        continue
    fi
    log INFO "  $name (line $li): $rtype $cur  ->  A $TARGET_IP"

    edit_json=$(jq -nc \
        --argjson li "$li" \
        --arg dn "$name" \
        --argjson ttl "$TTL" \
        --arg ip "$TARGET_IP" \
        '{line_index:$li, dname:$dn, record_type:"A", ttl:$ttl, data:[$ip]}')
    encoded=$(printf '%s' "$edit_json" | jq -sRr @uri)
    edit_params+=("edit=${encoded}")
    changed+=("$name")
done

if [ "${#edit_params[@]}" -eq 0 ]; then
    log INFO "all records already correct, nothing to do"
    exit 0
fi

# Safety guard: never push more edits than there are homeN names in scope.
# If this fires, something is wrong with name matching — abort rather than
# risk touching unrelated records.
if [ "${#edit_params[@]}" -gt "${#NAMES[@]}" ]; then
    log ERROR "safety abort: ${#edit_params[@]} edits queued but only ${#NAMES[@]} names in scope"
    exit 3
fi

# 4. Dry-run guard
if [ "${1:-}" != "--apply" ]; then
    log INFO "DRY RUN — ${#edit_params[@]} edit(s) queued for: ${changed[*]}"
    log INFO "re-run with --apply to push"
    exit 0
fi

# 5. Submit all edits in a single mass_edit_zone call
query="zone=${ZONE}&serial=${serial}"
for ep in "${edit_params[@]}"; do
    query+="&${ep}"
done

log INFO "pushing ${#edit_params[@]} edit(s) to cPanel"
response=$(bash "$WRAPPER" DNS/mass_edit_zone "$query")

if echo "$response" | jq -e '.status == 1' >/dev/null; then
    new_serial=$(echo "$response" | jq -r '.data.new_serial // "?"')
    log INFO "success: new_serial=${new_serial}"
else
    log ERROR "edit rejected: $(echo "$response" | jq -c '.errors // .')"
    exit 2
fi
