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
VLLM_BASE_IMAGE="${VLLM_BASE_IMAGE:-vllm/vllm-openai:latest}"
DOCKER_PULL_RETRIES="${DOCKER_PULL_RETRIES:-3}"
DOCKER_PULL_RETRY_WAIT="${DOCKER_PULL_RETRY_WAIT:-10}"
SKIP_GATEWAY_PULL="${SKIP_GATEWAY_PULL:-0}"
SKIP_VLLM_BASE_PULL="${SKIP_VLLM_BASE_PULL:-0}"
ZSTD_LEVEL="${ZSTD_LEVEL:-19}"
ZSTD_THREADS="${ZSTD_THREADS:-0}"
MIRROR_PROFILE="${MIRROR_PROFILE:-default}"
CN_IMAGE_GATEWAY="${CN_IMAGE_GATEWAY:-docker.m.daocloud.io/library/nginx:stable}"
CN_VLLM_BASE_IMAGE="${CN_VLLM_BASE_IMAGE:-docker.m.daocloud.io/vllm/vllm-openai:latest}"

if [[ "${MIRROR_PROFILE}" == "cn" ]]; then
  if [[ "${IMAGE_GATEWAY}" == "nginx:stable" ]]; then
    IMAGE_GATEWAY="${CN_IMAGE_GATEWAY}"
  fi
  if [[ "${VLLM_BASE_IMAGE}" == "vllm/vllm-openai:latest" ]]; then
    VLLM_BASE_IMAGE="${CN_VLLM_BASE_IMAGE}"
  fi
  log "MIRROR_PROFILE=cn enabled: IMAGE_GATEWAY=${IMAGE_GATEWAY}, VLLM_BASE_IMAGE=${VLLM_BASE_IMAGE}"
fi

require_docker
require_cmd conda
mkdir -p "${MODEL_DIR}" "${DIST_DIR}" "${TMP_DIR}"

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

ensure_hf_python_deps_in_conda_env() {
  if conda env list | awk '{print $1}' | rg -x "${HF_CONDA_ENV}" >/dev/null 2>&1; then
    log "Conda env ${HF_CONDA_ENV} already exists"
  else
    log "Creating conda env ${HF_CONDA_ENV} (python=${HF_CONDA_PYTHON})"
    conda create -y -n "${HF_CONDA_ENV}" "python=${HF_CONDA_PYTHON}"
  fi

  if conda run -n "${HF_CONDA_ENV}" python -c "import huggingface_hub" >/dev/null 2>&1; then
    log "huggingface_hub already installed in ${HF_CONDA_ENV}"
  else
    log "Installing huggingface_hub in conda env ${HF_CONDA_ENV}"
    conda run -n "${HF_CONDA_ENV}" python -m pip install huggingface_hub
  fi
}

download_model_via_python_api() {
  log "Downloading model ${MODEL_ID} into ${MODEL_DIR} (via conda env ${HF_CONDA_ENV})"
  conda run -n "${HF_CONDA_ENV}" python - <<PY
from huggingface_hub import snapshot_download
snapshot_download(
    repo_id="${MODEL_ID}",
    local_dir="${MODEL_DIR}",
    local_dir_use_symlinks=False,
)
print("Model download completed: ${MODEL_DIR}")
PY
}

ensure_hf_python_deps_in_conda_env
download_model_via_python_api

if [[ "${SKIP_GATEWAY_PULL}" == "1" ]]; then
  log "SKIP_GATEWAY_PULL=1, skip pulling ${IMAGE_GATEWAY}"
else
  log "Pulling gateway image ${IMAGE_GATEWAY}"
  if ! retry_docker_pull "${IMAGE_GATEWAY}" "${DOCKER_PULL_RETRIES}" "${DOCKER_PULL_RETRY_WAIT}"; then
    if docker image inspect "${IMAGE_GATEWAY}" >/dev/null 2>&1; then
      log "Pull failed but local image ${IMAGE_GATEWAY} exists, continue"
    else
      echo "Failed to pull ${IMAGE_GATEWAY}. If network to Docker Hub is unstable, set SKIP_GATEWAY_PULL=1 and pre-load image via docker load." >&2
      exit 1
    fi
  fi
fi

if [[ "${SKIP_VLLM_BASE_PULL}" == "1" ]]; then
  log "SKIP_VLLM_BASE_PULL=1, skip pulling ${VLLM_BASE_IMAGE}"
else
  log "Ensuring vLLM base image ${VLLM_BASE_IMAGE} is available"
  if ! retry_docker_pull "${VLLM_BASE_IMAGE}" "${DOCKER_PULL_RETRIES}" "${DOCKER_PULL_RETRY_WAIT}"; then
    if docker image inspect "${VLLM_BASE_IMAGE}" >/dev/null 2>&1; then
      log "Pull failed but local base image ${VLLM_BASE_IMAGE} exists, continue"
    else
      echo "Failed to pull ${VLLM_BASE_IMAGE}. Set VLLM_BASE_IMAGE to your mirror or pre-load image and set SKIP_VLLM_BASE_PULL=1." >&2
      exit 1
    fi
  fi
fi

log "Building inference image ${IMAGE_INFERENCE}"
docker build \
  --build-arg VLLM_BASE_IMAGE="${VLLM_BASE_IMAGE}" \
  -t "${IMAGE_INFERENCE}" \
  -f "${DEPLOY_DIR}/vllm/Dockerfile" \
  "${ROOT_DIR}"

log "Saving docker images into ${BUNDLE_TAR}"
docker save -o "${TMP_DIR}/images.tar" "${IMAGE_INFERENCE}" "${IMAGE_GATEWAY}"
cp "${TMP_DIR}/images.tar" "${BUNDLE_TAR}"

if command -v zstd >/dev/null 2>&1; then
  log "Compressing bundle with zstd"
  zstd -f -"${ZSTD_LEVEL}" -T"${ZSTD_THREADS}" "${BUNDLE_TAR}" -o "${BUNDLE_TAR}.zst"
else
  log "zstd not found, skipping compression"
fi

log "Bundle ready under ${DIST_DIR}"
