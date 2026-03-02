#!/bin/sh
set -euo pipefail

LISTEN_PORT="${LISTEN_PORT:-8000}"
VLLM_LOCAL_PORT="${VLLM_LOCAL_PORT:-18000}"
WHITELIST_FILE="/etc/nginx/whitelist.conf"

if [ ! -f "$WHITELIST_FILE" ]; then
    echo "ERROR: whitelist file not found at $WHITELIST_FILE"
    echo "Please mount a whitelist file containing allow rules and a final 'deny all;' line."
    exit 1
fi

if ! grep -qE '^[[:space:]]*deny[[:space:]]+all;[[:space:]]*$' "$WHITELIST_FILE"; then
    echo "ERROR: whitelist file must contain a line with 'deny all;'"
    echo "Current file: $WHITELIST_FILE"
    exit 1
fi

export LISTEN_PORT VLLM_LOCAL_PORT
envsubst '${LISTEN_PORT} ${VLLM_LOCAL_PORT}' \
    < /etc/nginx/nginx.conf.template \
    > /etc/nginx/nginx.conf

exec nginx -g 'daemon off;'
