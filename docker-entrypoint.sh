#!/usr/bin/env bash
set -euo pipefail

: "${UPSTREAM_HOST:?ERROR: UPSTREAM_HOST is required}"
: "${API_KEY:?ERROR: API_KEY is required}"

UPSTREAM_PORT="${UPSTREAM_PORT:-8000}"
RATE_LIMIT_RPS="${RATE_LIMIT_RPS:-5}"
RATE_LIMIT_BURST="${RATE_LIMIT_BURST:-20}"
SERVER_PORT="${SERVER_PORT:-80}"

WHITELIST_FILE="/etc/nginx/whitelist.conf"
if [ ! -f "${WHITELIST_FILE}" ]; then
    echo "ERROR: ${WHITELIST_FILE} not found. Mount your whitelist file to this path." >&2
    exit 1
fi

if ! grep -Eq '^[[:space:]]*deny[[:space:]]+all;[[:space:]]*$' "${WHITELIST_FILE}"; then
    echo "ERROR: ${WHITELIST_FILE} must contain a final deny rule: deny all;" >&2
    exit 1
fi

export UPSTREAM_HOST API_KEY UPSTREAM_PORT RATE_LIMIT_RPS RATE_LIMIT_BURST SERVER_PORT
envsubst '${UPSTREAM_HOST} ${API_KEY} ${UPSTREAM_PORT} ${RATE_LIMIT_RPS} ${RATE_LIMIT_BURST} ${SERVER_PORT}' \
    < /etc/nginx/nginx.conf.template \
    > /etc/nginx/nginx.conf

exec nginx -g 'daemon off;'
