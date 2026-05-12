#!/usr/bin/env bash
# One-shot test: lower home5 CNAME TTL from 14400 -> 300.
# Target/value unchanged. Easy revert: same script with TTL_NEW=14400.
set -euo pipefail

ZONE="compagnie-lily.org"
LINE_INDEX=47
DNAME="home5"
RTYPE="CNAME"
TARGET="77d.ddns.net."
TTL_NEW=300

# Get current serial fresh from the zone
SERIAL=$(bash "$(dirname "$0")/cpanel-api.sh" DNS/parse_zone "zone=${ZONE}" \
  | jq -r '.data[] | select(.record_type=="SOA") | .data_b64[2] | @base64d')

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

bash "$(dirname "$0")/cpanel-api.sh" DNS/mass_edit_zone "$QUERY" | jq
