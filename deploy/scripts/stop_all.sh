#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/common.sh"

require_docker

for c in "${GATEWAY_CONTAINER_NAME}" "${INFERENCE_CONTAINER_NAME}"; do
  if docker ps -a --format '{{.Names}}' | rg -x "${c}" >/dev/null 2>&1; then
    log "Stopping and removing ${c}"
    docker rm -f "${c}" >/dev/null
  else
    log "Container ${c} not found, skipped"
  fi
done

log "All target containers processed"
