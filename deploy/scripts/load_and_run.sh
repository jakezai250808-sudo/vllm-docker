#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/common.sh"

DIST_DIR="${DEPLOY_DIR}/dist"

require_docker

shopt -s nullglob
zst_files=("${DIST_DIR}"/*.tar.zst)
for file in "${zst_files[@]}"; do
  if command -v zstd >/dev/null 2>&1; then
    log "Decompressing ${file}"
    zstd -d -f "${file}" -o "${file%.zst}"
  else
    echo "Found ${file} but zstd is missing. Install zstd or provide *.tar." >&2
    exit 1
  fi
done

load_files=("${DIST_DIR}"/*.tar)
if [[ ${#load_files[@]} -eq 0 ]]; then
  echo "No tar bundles found in ${DIST_DIR}" >&2
  exit 1
fi

for file in "${load_files[@]}"; do
  log "Loading docker image bundle ${file}"
  docker load -i "${file}"
done

if [[ -z "${API_KEY:-}" ]]; then
  echo "API_KEY is not set. Export API_KEY or place it in deploy/.env before running." >&2
  exit 1
fi

"${SCRIPT_DIR}/run_inference.sh"
"${SCRIPT_DIR}/run_gateway.sh"
"${SCRIPT_DIR}/status.sh"
