#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/common.sh"

MODEL_ID="Qwen/Qwen3-Coder-Next"
MODEL_DIR="${DEPLOY_DIR}/assets/models/Qwen3-Coder-Next"
DIST_DIR="${DEPLOY_DIR}/dist"
BUNDLE_TAR="${DIST_DIR}/qwen3_coder_next_stack.tar"
TMP_DIR="${DIST_DIR}/tmp"

require_docker
require_cmd python3

ensure_huggingface_cli() {
  if command -v huggingface-cli >/dev/null 2>&1; then
    return 0
  fi

  if ! python3 -m pip --version >/dev/null 2>&1; then
    log "pip for python3 not found, trying ensurepip"
    python3 -m ensurepip --upgrade
  fi

  log "huggingface-cli not found, trying to install huggingface_hub[cli] via pip"
  python3 -m pip install --user "huggingface_hub[cli]"

  if command -v huggingface-cli >/dev/null 2>&1; then
    return 0
  fi

  local user_bin
  user_bin="$(python3 -m site --user-base)/bin"
  if [[ -x "${user_bin}/huggingface-cli" ]]; then
    export PATH="${user_bin}:${PATH}"
    return 0
  fi

  echo "huggingface-cli installation failed. Please run: python3 -m pip install --user 'huggingface_hub[cli]'" >&2
  exit 1
}

ensure_huggingface_cli
mkdir -p "${MODEL_DIR}" "${DIST_DIR}" "${TMP_DIR}"

log "Downloading model ${MODEL_ID} into ${MODEL_DIR}"
huggingface-cli download "${MODEL_ID}" --local-dir "${MODEL_DIR}" --local-dir-use-symlinks False

log "Pulling gateway image ${IMAGE_GATEWAY}"
docker pull "${IMAGE_GATEWAY}"

log "Building inference image ${IMAGE_INFERENCE}"
docker build -t "${IMAGE_INFERENCE}" -f "${DEPLOY_DIR}/vllm/Dockerfile" "${ROOT_DIR}"

log "Saving docker images into ${BUNDLE_TAR}"
docker save -o "${TMP_DIR}/images.tar" "${IMAGE_INFERENCE}" "${IMAGE_GATEWAY}"
cp "${TMP_DIR}/images.tar" "${BUNDLE_TAR}"

if command -v zstd >/dev/null 2>&1; then
  log "Compressing bundle with zstd"
  zstd -f -19 "${BUNDLE_TAR}" -o "${BUNDLE_TAR}.zst"
else
  log "zstd not found, skipping compression"
fi

log "Bundle ready under ${DIST_DIR}"
