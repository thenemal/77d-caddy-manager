#!/usr/bin/env bash
# One-shot smoke test of the cPanel DNS write path: nudges home2's A-record TTL.
# Target/value unchanged -- only the TTL moves. Easy revert: TTL_NEW=300.
#
# The line_index is looked up by name at runtime, NOT hardcoded: removing a
# record renumbers every index after it, so a stale constant will silently
# rewrite whichever record slid into that slot.
#
# Note: the cron updater rewrites these records with TTL=300 every 5 min, so a
# non-300 TTL set here self-heals on the next run.
set -euo pipefail

ZONE="compagnie-lily.org"
DNAME="home2"
RTYPE="A"
TTL_NEW=301

WRAPPER="$(dirname "$0")/cpanel-api.sh"

ZONE_JSON=$(bash "$WRAPPER" DNS/parse_zone "zone=${ZONE}")

# Current SOA serial -- mass_edit_zone rejects a stale one (concurrent-edit guard)
SERIAL=$(jq -r '.data[] | select(.record_type=="SOA") | .data_b64[2] | @base64d' <<<"$ZONE_JSON")

# Resolve line_index + current value for $DNAME/$RTYPE
read -r LINE_INDEX TARGET < <(jq -r --arg dn "$DNAME" --arg rt "$RTYPE" '
  .data[]
  | select(.dname_b64 and (.dname_b64|@base64d) == $dn and .record_type == $rt)
  | "\(.line_index) \(.data_b64[0]|@base64d)"' <<<"$ZONE_JSON")

if [ -z "${LINE_INDEX:-}" ]; then
  echo "no ${RTYPE} record for ${DNAME} in ${ZONE}; aborting" >&2
  exit 1
fi

EDIT_JSON=$(jq -nc \
  --argjson li "$LINE_INDEX" \
  --arg dn "$DNAME" \
  --arg rt "$RTYPE" \
  --argjson ttl "$TTL_NEW" \
  --arg tgt "$TARGET" \
  '{line_index:$li, dname:$dn, record_type:$rt, ttl:$ttl, data:[$tgt]}')

EDIT_ENC=$(printf '%s' "$EDIT_JSON" | jq -sRr @uri)
QUERY="zone=${ZONE}&serial=${SERIAL}&edit=${EDIT_ENC}"

echo "Submitting edit:"
echo "  serial:   ${SERIAL}"
echo "  edit:     ${EDIT_JSON}"
echo

bash "$WRAPPER" DNS/mass_edit_zone "$QUERY" | jq
