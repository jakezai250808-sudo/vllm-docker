#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/common.sh"

# RTX 5000 (16GB) friendly default model for vLLM smoke/functional tests.
MODEL_ID="${MODEL_ID:-Qwen/Qwen2.5-1.5B-Instruct}"
MODEL_ALIAS="${MODEL_ALIAS:-Qwen2.5-1.5B-Instruct}"
MODEL_DIR="${MODEL_DIR:-${DEPLOY_DIR}/assets/models/${MODEL_ALIAS}}"
MODEL_BUILD_DIR="${MODEL_BUILD_DIR:-${DEPLOY_DIR}/vllm/models/${MODEL_ALIAS}}"
HF_CONDA_ENV="${HF_CONDA_ENV:-llm-offline-hf}"
HF_CONDA_PYTHON="${HF_CONDA_PYTHON:-3.10}"
SYNC_TO_BUILD_CONTEXT="${SYNC_TO_BUILD_CONTEXT:-1}"

require_cmd conda
mkdir -p "${DEPLOY_DIR}/assets/models" "${DEPLOY_DIR}/vllm/models"

ensure_hf_python_deps_in_conda_env() {
  if conda env list | awk '{print $1}' | grep -Fx "${HF_CONDA_ENV}" >/dev/null 2>&1; then
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
  log "Downloading model ${MODEL_ID} into ${MODEL_DIR}"
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

if [[ "${SYNC_TO_BUILD_CONTEXT}" == "1" ]]; then
  log "Syncing model into docker build context ${MODEL_BUILD_DIR}"
  rm -rf "${MODEL_BUILD_DIR}"
  cp -a "${MODEL_DIR}" "${MODEL_BUILD_DIR}"
fi

log "Done. Use MODEL_PATH=/models/${MODEL_ALIAS} when running inference image."
