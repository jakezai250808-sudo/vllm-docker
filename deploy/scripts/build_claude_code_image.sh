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
CLAUDE_NPM_REGISTRY="${CLAUDE_NPM_REGISTRY:-}"
CLAUDE_ENDPOINT="${CLAUDE_ENDPOINT:-}"
CLAUDE_AK="${CLAUDE_AK:-}"
CLAUDE_MODEL="${CLAUDE_MODEL:-}"
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

ARG NPM_REGISTRY
ARG endpoint
ARG ak
ARG model
ENV NPM_CONFIG_UPDATE_NOTIFIER=false
ENV NODE_TLS_REJECT_UNAUTHORIZED=0

RUN if [ -n "\${NPM_REGISTRY}" ]; then \
      npm config set registry "\${NPM_REGISTRY}"; \
    fi \
    && npm config set strict-ssl false \
    && npm config set fund false \
    && echo "[claude-build] strict-ssl=\$(npm config get strict-ssl), NODE_TLS_REJECT_UNAUTHORIZED=\${NODE_TLS_REJECT_UNAUTHORIZED}" \
    && echo "[claude-build] npm registry=\$(npm config get registry)" \
    && npm install -g ${CLAUDE_NPM_PACKAGE} \
    && if command -v ${CLAUDE_BIN} >/dev/null 2>&1; then \
         echo "[claude-build] binary ${CLAUDE_BIN} already available"; \
       elif command -v claude-code >/dev/null 2>&1; then \
         ln -sf "\$(command -v claude-code)" "/usr/local/bin/${CLAUDE_BIN}"; \
         echo "[claude-build] linked ${CLAUDE_BIN} -> claude-code"; \
       else \
         PKG_JSON="\$(npm root -g)/${CLAUDE_NPM_PACKAGE}/package.json"; \
         if [ -f "\${PKG_JSON}" ]; then \
           BIN_PATH="\$(node -e 'const fs=require("fs"); const p=process.argv[1]; const j=JSON.parse(fs.readFileSync(p,"utf8")); const b=j.bin; if(typeof b=="string"){process.stdout.write(b);} else if(b && typeof b=="object"){const ks=Object.keys(b); if(ks.length){process.stdout.write(String(b[ks[0]]));}}' "\${PKG_JSON}")"; \
           if [ -n "\${BIN_PATH}" ] && [ -f "\$(dirname "\${PKG_JSON}")/\${BIN_PATH}" ]; then \
             ln -sf "\$(dirname "\${PKG_JSON}")/\${BIN_PATH}" "/usr/local/bin/${CLAUDE_BIN}"; \
             chmod +x "/usr/local/bin/${CLAUDE_BIN}"; \
             echo "[claude-build] linked ${CLAUDE_BIN} -> \${BIN_PATH} from package.json"; \
           fi; \
         fi; \
         command -v ${CLAUDE_BIN} >/dev/null 2>&1 || { echo "[claude-build] no expected claude binary found after npm install" >&2; exit 1; }; \
       fi \
    && { \
         echo "export endpoint=\${endpoint}"; \
         echo "export ak=\${ak}"; \
         echo "export model=\${model}"; \
       } >> /root/.bashrc \
    && npm cache clean --force

WORKDIR /workspace

ENTRYPOINT ["${CLAUDE_BIN}"]
DOCKERFILE

if [[ -n "${CLAUDE_NPM_REGISTRY}" ]]; then
  log "Building Claude Code client image ${CLAUDE_IMAGE} with npm registry ${CLAUDE_NPM_REGISTRY}"
else
  log "Building Claude Code client image ${CLAUDE_IMAGE} with default npm registry"
fi

log "Injecting bashrc vars: endpoint=${CLAUDE_ENDPOINT:-<empty>} ak=${CLAUDE_AK:+<set>} model=${CLAUDE_MODEL:-<empty>}"

docker build \
  --build-arg NPM_REGISTRY="${CLAUDE_NPM_REGISTRY}" \
  --build-arg endpoint="${CLAUDE_ENDPOINT}" \
  --build-arg ak="${CLAUDE_AK}" \
  --build-arg model="${CLAUDE_MODEL}" \
  -t "${CLAUDE_IMAGE}" \
  -f "${DOCKERFILE_PATH}" \
  "${TMP_DIR}"

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
