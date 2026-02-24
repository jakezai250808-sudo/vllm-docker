#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/common.sh"

API_KEY="${API_KEY:-}"
if [[ -z "${API_KEY}" ]]; then
  echo "API_KEY is required. Export it or set deploy/.env." >&2
  exit 1
fi

require_docker
ensure_network
ensure_image "${IMAGE_GATEWAY}"

TEMPLATE="${DEPLOY_DIR}/nginx/nginx.conf.template"
RENDER_DIR="${DEPLOY_DIR}/generated"
RENDERED_CONF="${RENDER_DIR}/nginx.conf"
mkdir -p "${RENDER_DIR}"

limit_req_directive="            # Rate limiting disabled (ENABLE_RATE_LIMIT=off)"
if [[ "${ENABLE_RATE_LIMIT}" == "on" ]]; then
  limit_req_directive="            limit_req zone=llm_per_ip burst=${LIMIT_REQ_BURST} nodelay;"
fi

escaped_api_key="$(printf '%s' "${API_KEY}" | sed 's/[&/]/\\&/g')"
escaped_body_size="$(printf '%s' "${MAX_BODY_SIZE}" | sed 's/[&/]/\\&/g')"
escaped_connect_timeout="$(printf '%s' "${PROXY_CONNECT_TIMEOUT}" | sed 's/[&/]/\\&/g')"
escaped_read_timeout="$(printf '%s' "${PROXY_READ_TIMEOUT}" | sed 's/[&/]/\\&/g')"
escaped_send_timeout="$(printf '%s' "${PROXY_SEND_TIMEOUT}" | sed 's/[&/]/\\&/g')"
escaped_limit_rate="$(printf '%s' "${LIMIT_REQ_RATE}" | sed 's/[&/]/\\&/g')"

sed \
  -e "s/__API_KEY__/${escaped_api_key}/g" \
  -e "s/__MAX_BODY_SIZE__/${escaped_body_size}/g" \
  -e "s/__PROXY_CONNECT_TIMEOUT__/${escaped_connect_timeout}/g" \
  -e "s/__PROXY_READ_TIMEOUT__/${escaped_read_timeout}/g" \
  -e "s/__PROXY_SEND_TIMEOUT__/${escaped_send_timeout}/g" \
  -e "s/__LIMIT_REQ_RATE__/${escaped_limit_rate}/g" \
  -e "s|__LIMIT_REQ_DIRECTIVE__|${limit_req_directive}|g" \
  "${TEMPLATE}" > "${RENDERED_CONF}"

remove_container_if_exists "${GATEWAY_CONTAINER_NAME}"

log "Starting gateway container ${GATEWAY_CONTAINER_NAME} on ${GATEWAY_PORT}"
docker run -d --restart unless-stopped \
  --name "${GATEWAY_CONTAINER_NAME}" \
  --network "${NETWORK_NAME}" \
  -p "${GATEWAY_PORT}:8080" \
  -v "${RENDERED_CONF}:/etc/nginx/nginx.conf:ro" \
  "${IMAGE_GATEWAY}"

log "Gateway started. Check logs: docker logs -f ${GATEWAY_CONTAINER_NAME}"
