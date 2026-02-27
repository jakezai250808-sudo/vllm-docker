#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/common.sh"

DIST_DIR="${DEPLOY_DIR}/dist"
TMP_DIR="${DIST_DIR}/tmp-claude-code"
CLAUDE_IMAGE="${CLAUDE_IMAGE:-corp/claude-code-client:latest}"
CLAUDE_BASE_IMAGE="${CLAUDE_BASE_IMAGE:-node:20}"
CLAUDE_NPM_PACKAGE="${CLAUDE_NPM_PACKAGE:-@anthropic-ai/claude-code}"
CLAUDE_BIN="${CLAUDE_BIN:-claude}"
DOCKER_PULL_RETRIES="${DOCKER_PULL_RETRIES:-3}"
DOCKER_PULL_RETRY_WAIT="${DOCKER_PULL_RETRY_WAIT:-10}"
SAVE_IMAGE_TAR="${SAVE_IMAGE_TAR:-0}"
BUNDLE_TAR="${DIST_DIR}/claude_code_client.tar"
ZSTD_LEVEL="${ZSTD_LEVEL:-6}"
ZSTD_THREADS="${ZSTD_THREADS:-0}"

retry_docker_pull() {
  local image="$1"
  local retries="${2:-3}"
  local wait_s="${3:-10}"
  local n=1

  while [[ "${n}" -le "${retries}" ]]; do
    if docker pull "${image}"; then
      return 0
    fi
    if [[ "${n}" -lt "${retries}" ]]; then
      log "docker pull failed for ${image}, retry ${n}/${retries} after ${wait_s}s"
      sleep "${wait_s}"
    fi
    n=$((n + 1))
  done
  return 1
}

require_docker
mkdir -p "${DIST_DIR}" "${TMP_DIR}"

if docker image inspect "${CLAUDE_BASE_IMAGE}" >/dev/null 2>&1; then
  log "Base image already exists locally, skip pull: ${CLAUDE_BASE_IMAGE}"
else
  log "Base image not found locally, pulling: ${CLAUDE_BASE_IMAGE}"
  if ! retry_docker_pull "${CLAUDE_BASE_IMAGE}" "${DOCKER_PULL_RETRIES}" "${DOCKER_PULL_RETRY_WAIT}"; then
    echo "Failed to pull base image ${CLAUDE_BASE_IMAGE} and no local copy found." >&2
    exit 1
  fi
fi

DOCKERFILE_PATH="${TMP_DIR}/Dockerfile.claude-code"
cat > "${DOCKERFILE_PATH}" <<DOCKERFILE
FROM ${CLAUDE_BASE_IMAGE}

ENV NPM_CONFIG_UPDATE_NOTIFIER=false

RUN npm install -g ${CLAUDE_NPM_PACKAGE} \
    && npm cache clean --force

WORKDIR /workspace

ENTRYPOINT ["${CLAUDE_BIN}"]
DOCKERFILE

log "Building Claude Code client image ${CLAUDE_IMAGE}"
docker build -t "${CLAUDE_IMAGE}" -f "${DOCKERFILE_PATH}" "${TMP_DIR}"

log "Validating CLI binary in image"
if ! docker run --rm --entrypoint /bin/sh "${CLAUDE_IMAGE}" -lc "command -v ${CLAUDE_BIN}" >/dev/null 2>&1; then
  echo "Claude CLI binary ${CLAUDE_BIN} not found in image. Consider overriding CLAUDE_BIN or CLAUDE_NPM_PACKAGE." >&2
  exit 1
fi

log "Image build complete: ${CLAUDE_IMAGE}"

if [[ "${SAVE_IMAGE_TAR}" == "1" ]]; then
  log "Saving image tar: ${BUNDLE_TAR}"
  docker save -o "${BUNDLE_TAR}" "${CLAUDE_IMAGE}"

  if command -v zstd >/dev/null 2>&1; then
    log "Compressing tar with zstd"
    zstd -f -"${ZSTD_LEVEL}" -T"${ZSTD_THREADS}" "${BUNDLE_TAR}" -o "${BUNDLE_TAR}.zst"
  else
    log "zstd not found, skip compression"
  fi
fi

log "Done"
