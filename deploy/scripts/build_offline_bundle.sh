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
HF_CONDA_ENV="${HF_CONDA_ENV:-llm-offline-hf}"
HF_CONDA_PYTHON="${HF_CONDA_PYTHON:-3.10}"

require_docker
require_cmd conda
mkdir -p "${MODEL_DIR}" "${DIST_DIR}" "${TMP_DIR}"

ensure_hf_cli_in_conda_env() {
  if conda env list | awk '{print $1}' | rg -x "${HF_CONDA_ENV}" >/dev/null 2>&1; then
    log "Conda env ${HF_CONDA_ENV} already exists"
  else
    log "Creating conda env ${HF_CONDA_ENV} (python=${HF_CONDA_PYTHON})"
    conda create -y -n "${HF_CONDA_ENV}" "python=${HF_CONDA_PYTHON}"
  fi

  if conda run -n "${HF_CONDA_ENV}" python -c "import huggingface_hub" >/dev/null 2>&1; then
    log "huggingface_hub already installed in ${HF_CONDA_ENV}"
  else
    log "Installing huggingface_hub[cli] into conda env ${HF_CONDA_ENV}"
    conda run -n "${HF_CONDA_ENV}" python -m pip install "huggingface_hub[cli]"
  fi

  conda run -n "${HF_CONDA_ENV}" huggingface-cli --help >/dev/null
}

ensure_hf_cli_in_conda_env

log "Downloading model ${MODEL_ID} into ${MODEL_DIR} (via conda env ${HF_CONDA_ENV})"
conda run -n "${HF_CONDA_ENV}" huggingface-cli download \
  "${MODEL_ID}" \
  --local-dir "${MODEL_DIR}" \
  --local-dir-use-symlinks False

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
