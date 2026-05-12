#!/usr/bin/env bash
# Thin wrapper around cPanel UAPI.
# Usage:
#   ./cpanel-api.sh <module>/<function> [query_string]
# Examples:
#   ./cpanel-api.sh Variables/get_user_information
#   ./cpanel-api.sh DNS/parse_zone zone=compagnie-lily.org
set -euo pipefail

ENV_FILE="$(dirname "$0")/.cpanel-api.env"
if [[ ! -r "$ENV_FILE" ]]; then
    echo "missing $ENV_FILE" >&2
    exit 2
fi
# shellcheck disable=SC1090
set -a; . "$ENV_FILE"; set +a

: "${CPANEL_HOST:?}" "${CPANEL_PORT:?}" "${CPANEL_USER:?}" "${CPANEL_TOKEN:?}"

endpoint="${1:?endpoint required, e.g. Variables/get_user_information}"
query="${2:-}"

url="https://${CPANEL_HOST}:${CPANEL_PORT}/execute/${endpoint}"
[[ -n "$query" ]] && url="${url}?${query}"

curl -sS --max-time 20 \
    -H "Authorization: cpanel ${CPANEL_USER}:${CPANEL_TOKEN}" \
    "$url"
