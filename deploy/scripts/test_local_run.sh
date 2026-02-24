#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/common.sh"

DOCKER_PULL_RETRIES="${DOCKER_PULL_RETRIES:-3}"
DOCKER_PULL_RETRY_WAIT="${DOCKER_PULL_RETRY_WAIT:-10}"
SKIP_GATEWAY_PULL="${SKIP_GATEWAY_PULL:-0}"
RUN_STACK="${RUN_STACK:-1}"
ENABLE_GPU="${ENABLE_GPU:-1}"
CUDA_TEST_IMAGE="${CUDA_TEST_IMAGE:-nvidia/cuda:12.1.0-base-ubuntu22.04}"
INFERENCE_IMAGE="${INFERENCE_IMAGE:-${IMAGE_INFERENCE}}"
TP="${TP:-1}"
PORT="${INFERENCE_PORT:-8000}"
MAX_MODEL_LEN="${MAX_MODEL_LEN:-4096}"
DTYPE="${DTYPE:-auto}"
CUDA_VISIBLE_DEVICES="${CUDA_VISIBLE_DEVICES:-}"
EXTRA_ARGS="${EXTRA_ARGS:-}"
MODEL_ASSET_DIR="${DEPLOY_DIR}/assets/models/Qwen3-Coder-Next"
MODEL_BUILD_DIR="${DEPLOY_DIR}/vllm/models/Qwen3-Coder-Next"
GPU_MODE="none"

info() {
  log "[INFO] $*" >&2
}

warn() {
  log "[WARN] $*" >&2
}

error() {
  log "[ERROR] $*" >&2
}

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
      warn "docker pull failed for ${image}, retry ${n}/${retries} after ${wait_s}s"
      sleep "${wait_s}"
    fi

    n=$((n + 1))
  done

  return 1
}

ensure_image_or_pull() {
  local image="$1"

  if docker image inspect "${image}" >/dev/null 2>&1; then
    return 0
  fi

  warn "Image not found locally: ${image}; trying docker pull"
  if retry_docker_pull "${image}" "${DOCKER_PULL_RETRIES}" "${DOCKER_PULL_RETRY_WAIT}"; then
    return 0
  fi

  warn "Unable to pull image ${image} (network/registry may be unavailable)"
  warn "If your environment is offline, please docker load this image first (example: ${image})."
  return 1
}

print_environment_summary() {
  local driver_version="unknown"

  info "========== Local GPU Smoke Summary =========="
  info "Docker version: $(docker --version 2>/dev/null || echo unavailable)"

  if command -v nvidia-smi >/dev/null 2>&1; then
    driver_version="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -n 1 || true)"
    if [[ -n "${driver_version}" ]]; then
      info "Host NVIDIA driver version: ${driver_version}"
    else
      warn "Unable to parse host NVIDIA driver version from nvidia-smi"
    fi

    info "Host nvidia-smi:"
    nvidia-smi || warn "Host nvidia-smi command exists but failed"
  else
    warn "Host nvidia-smi not found in PATH"
  fi

  info "Selected CUDA_TEST_IMAGE: ${CUDA_TEST_IMAGE}"
}

print_cuda_compat_advice_if_needed() {
  local err_file="$1"

  if grep -Eqi 'unsatisfied condition: cuda>=12\.4|cuda>=12\.4' "${err_file}"; then
    error "Detected CUDA compatibility error (cuda>=12.4)."
    error "No need to upgrade Ubuntu or install CUDA Toolkit on host for this issue."
    error "To run cu124 containers, you need a newer NVIDIA driver; or switch to lower CUDA images (cu121/cu122)."
    error "For this script, prefer CUDA_TEST_IMAGE=nvidia/cuda:12.1.0-base-ubuntu22.04 on driver 530.x."
  fi
}

run_gpu_smoke_nvidia_smi() {
  local image="$1"
  local mode="$2"
  local err_file="$3"
  local -a cmd=(docker run --rm)

  if [[ "${mode}" == "gpus" ]]; then
    cmd+=(--gpus all)
  else
    cmd+=(--runtime=nvidia -e NVIDIA_VISIBLE_DEVICES=all -e NVIDIA_DRIVER_CAPABILITIES=compute,utility)
  fi

  cmd+=("${image}" nvidia-smi)

  if "${cmd[@]}" >/dev/null 2>"${err_file}"; then
    return 0
  fi

  print_cuda_compat_advice_if_needed "${err_file}"
  return 1
}

run_gpu_smoke_inference_image() {
  local image="$1"
  local mode="$2"
  local err_file="$3"
  local -a cmd=(docker run --rm --entrypoint python)

  if [[ "${mode}" == "gpus" ]]; then
    cmd+=(--gpus all)
  else
    cmd+=(--runtime=nvidia -e NVIDIA_VISIBLE_DEVICES=all -e NVIDIA_DRIVER_CAPABILITIES=compute,utility)
  fi

  if [[ -n "${CUDA_VISIBLE_DEVICES}" ]]; then
    cmd+=( -e "CUDA_VISIBLE_DEVICES=${CUDA_VISIBLE_DEVICES}" )
  fi

  cmd+=("${image}" -c 'import torch; print(torch.cuda.is_available())')

  if "${cmd[@]}" >"${err_file}.out" 2>"${err_file}"; then
    if grep -q '^True$' "${err_file}.out"; then
      return 0
    fi
  fi

  print_cuda_compat_advice_if_needed "${err_file}"
  return 1
}

preflight_inference_image_with_mode() {
  local mode="$1"
  local err_file
  err_file="$(mktemp)"
  local -a cmd=(docker run --rm)

  if [[ "${mode}" == "gpus" ]]; then
    cmd+=(--gpus all)
  elif [[ "${mode}" == "runtime" ]]; then
    cmd+=(--runtime=nvidia -e NVIDIA_VISIBLE_DEVICES=all -e NVIDIA_DRIVER_CAPABILITIES=compute,utility)
  fi

  if [[ -n "${CUDA_VISIBLE_DEVICES}" && "${mode}" != "none" ]]; then
    cmd+=( -e "CUDA_VISIBLE_DEVICES=${CUDA_VISIBLE_DEVICES}" )
  fi

  cmd+=(--entrypoint /bin/sh "${INFERENCE_IMAGE}" -c 'exit 0')

  if "${cmd[@]}" >/dev/null 2>"${err_file}"; then
    rm -f "${err_file}"
    return 0
  fi

  error "Inference image GPU preflight failed for GPU_MODE=${mode}."
  print_cuda_compat_advice_if_needed "${err_file}"
  error "Fix options:"
  error "  1) Update NVIDIA driver for the image CUDA requirement;"
  error "  2) Use an inference image built on lower CUDA base (cu121/cu122);"
  error "  3) Set ENABLE_GPU=0 for CPU mode."
  rm -f "${err_file}"
  return 1
}

detect_gpu_mode() {
  local err_file
  err_file="$(mktemp)"

  if [[ "${ENABLE_GPU}" != "1" ]]; then
    info "ENABLE_GPU=${ENABLE_GPU}, forcing CPU mode"
    rm -f "${err_file}"
    echo "none"
    return 0
  fi

  if ensure_image_or_pull "${CUDA_TEST_IMAGE}"; then
    info "GPU smoke test with CUDA image: ${CUDA_TEST_IMAGE}"

    if run_gpu_smoke_nvidia_smi "${CUDA_TEST_IMAGE}" gpus "${err_file}"; then
      rm -f "${err_file}" "${err_file}.out"
      echo "gpus"
      return 0
    fi

    warn "--gpus all smoke test failed, trying --runtime=nvidia"
    if run_gpu_smoke_nvidia_smi "${CUDA_TEST_IMAGE}" runtime "${err_file}"; then
      rm -f "${err_file}" "${err_file}.out"
      echo "runtime"
      return 0
    fi

    warn "CUDA image smoke tests failed for both --gpus all and --runtime=nvidia"
  else
    warn "CUDA test image unavailable: ${CUDA_TEST_IMAGE}"
  fi

  if docker image inspect "${INFERENCE_IMAGE}" >/dev/null 2>&1; then
    info "Fallback smoke test with inference image torch.cuda.is_available(): ${INFERENCE_IMAGE}"

    if run_gpu_smoke_inference_image "${INFERENCE_IMAGE}" gpus "${err_file}"; then
      rm -f "${err_file}" "${err_file}.out"
      echo "gpus"
      return 0
    fi

    warn "Inference image fallback with --gpus all failed, trying --runtime=nvidia"
    if run_gpu_smoke_inference_image "${INFERENCE_IMAGE}" runtime "${err_file}"; then
      rm -f "${err_file}" "${err_file}.out"
      echo "runtime"
      return 0
    fi

    warn "Inference image fallback smoke tests failed for both GPU modes"
  else
    warn "Inference image not present locally for fallback smoke test: ${INFERENCE_IMAGE}"
  fi

  error "GPU unavailable: both '--gpus all' and '--runtime=nvidia' smoke tests failed."
  error "Check nvidia-container-toolkit, host NVIDIA driver (nvidia-smi), and Docker daemon runtime configuration."
  error "If offline, docker load CUDA_TEST_IMAGE first: ${CUDA_TEST_IMAGE}"
  rm -f "${err_file}" "${err_file}.out"
  echo "none"
  return 0
}

start_inference_container() {
  local gpu_mode="$1"
  local -a gpu_args=()
  local -a run_cmd=(
    docker run -d --restart unless-stopped
    --name "${INFERENCE_CONTAINER_NAME}"
    --network "${NETWORK_NAME}"
  )

  if [[ "${gpu_mode}" == "gpus" ]]; then
    gpu_args=(--gpus all)
  elif [[ "${gpu_mode}" == "runtime" ]]; then
    gpu_args=(--runtime=nvidia -e NVIDIA_VISIBLE_DEVICES=all -e NVIDIA_DRIVER_CAPABILITIES=compute,utility)
  fi

  if [[ -n "${CUDA_VISIBLE_DEVICES}" && "${gpu_mode}" != "none" ]]; then
    gpu_args+=( -e "CUDA_VISIBLE_DEVICES=${CUDA_VISIBLE_DEVICES}" )
  fi

  run_cmd+=(
    "${gpu_args[@]}"
    -e "TP=${TP}"
    -e "PORT=${PORT}"
    -e "MAX_MODEL_LEN=${MAX_MODEL_LEN}"
    -e "DTYPE=${DTYPE}"
    -e "EXTRA_ARGS=${EXTRA_ARGS}"
    "--health-cmd=python -c \"import urllib.request; urllib.request.urlopen('http://127.0.0.1:8000/v1/models', timeout=5)\""
    --health-interval=30s
    --health-timeout=10s
    --health-retries=5
    --health-start-period=120s
    "${INFERENCE_IMAGE}"
  )

  info "GPU_MODE=${gpu_mode}"
  info "Inference docker run args: ${gpu_args[*]:-<none>}"
  info "Inference docker run command: docker run -d --restart unless-stopped --name ${INFERENCE_CONTAINER_NAME} --network ${NETWORK_NAME} ${gpu_args[*]} -e TP=${TP} -e PORT=${PORT} -e MAX_MODEL_LEN=${MAX_MODEL_LEN} -e DTYPE=${DTYPE} -e EXTRA_ARGS=<omitted> ... ${INFERENCE_IMAGE}"
  "${run_cmd[@]}"
}

require_docker
ensure_network
print_environment_summary

if [[ "${SKIP_GATEWAY_PULL}" != "1" ]] && ! docker image inspect "${IMAGE_GATEWAY}" >/dev/null 2>&1; then
  info "Pulling gateway image ${IMAGE_GATEWAY}"
  retry_docker_pull "${IMAGE_GATEWAY}" "${DOCKER_PULL_RETRIES}" "${DOCKER_PULL_RETRY_WAIT}"
fi

info "Preparing model files for docker build context"
if [[ ! -d "${MODEL_ASSET_DIR}" ]]; then
  error "Model assets not found: ${MODEL_ASSET_DIR}"
  error "Please run deploy/scripts/build_offline_bundle.sh first to download model assets."
  exit 1
fi
rm -rf "${MODEL_BUILD_DIR}"
mkdir -p "${DEPLOY_DIR}/vllm/models"
cp -a "${MODEL_ASSET_DIR}" "${MODEL_BUILD_DIR}"

info "Building local inference image ${INFERENCE_IMAGE} (no tar/zst bundle)"
docker build \
  -t "${INFERENCE_IMAGE}" \
  -f "${DEPLOY_DIR}/vllm/Dockerfile" \
  "${DEPLOY_DIR}/vllm"

if [[ "${RUN_STACK}" != "1" ]]; then
  info "RUN_STACK=${RUN_STACK}, build finished and skip starting containers"
  exit 0
fi

if [[ -z "${API_KEY:-}" ]]; then
  export API_KEY="${LOCAL_TEST_API_KEY:-local-test-key}"
  info "API_KEY not set, using LOCAL_TEST_API_KEY for local smoke test"
fi

remove_container_if_exists "${INFERENCE_CONTAINER_NAME}"
GPU_MODE="$(detect_gpu_mode)"

if [[ "${GPU_MODE}" != "none" ]]; then
  preflight_inference_image_with_mode "${GPU_MODE}"
fi

remove_container_if_exists "${INFERENCE_CONTAINER_NAME}"
start_inference_container "${GPU_MODE}"
bash "${SCRIPT_DIR}/run_gateway.sh"
bash "${SCRIPT_DIR}/status.sh"

info "GPU detection result: ${GPU_MODE}"
info "Summary: driver=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -n 1 || echo unknown), CUDA_TEST_IMAGE=${CUDA_TEST_IMAGE}, GPU_MODE=${GPU_MODE}, CUDA_VISIBLE_DEVICES=${CUDA_VISIBLE_DEVICES:-<unset>}"
info "Local test ready. Example: curl -H 'Authorization: Bearer ${API_KEY}' http://127.0.0.1:${GATEWAY_PORT}/v1/models"
