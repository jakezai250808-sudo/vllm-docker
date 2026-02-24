#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/common.sh"

VLLM_BASE_IMAGE="${VLLM_BASE_IMAGE:-vllm/vllm-openai:latest}"
DOCKER_PULL_RETRIES="${DOCKER_PULL_RETRIES:-3}"
DOCKER_PULL_RETRY_WAIT="${DOCKER_PULL_RETRY_WAIT:-10}"
SKIP_GATEWAY_PULL="${SKIP_GATEWAY_PULL:-0}"
SKIP_VLLM_BASE_PULL="${SKIP_VLLM_BASE_PULL:-0}"
RUN_STACK="${RUN_STACK:-1}"
ENABLE_GPU="${ENABLE_GPU:-1}"
CUDA_TEST_IMAGE="${CUDA_TEST_IMAGE:-nvidia/cuda:12.1.0-base-ubuntu22.04}"
INFERENCE_IMAGE="${INFERENCE_IMAGE:-${IMAGE_INFERENCE}}"
TP="${TP:-2}"
PORT="${INFERENCE_PORT:-8000}"
MAX_MODEL_LEN="${MAX_MODEL_LEN:-65536}"
DTYPE="${DTYPE:-auto}"
CUDA_VISIBLE_DEVICES="${CUDA_VISIBLE_DEVICES:-}"
EXTRA_ARGS="${EXTRA_ARGS:-}"

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
  return 1
}

print_environment_summary() {
  info "========== Local GPU Smoke Summary =========="
  info "Docker version: $(docker --version 2>/dev/null || echo unavailable)"
  if command -v nvidia-smi >/dev/null 2>&1; then
    info "Host nvidia-smi:"
    nvidia-smi || warn "Host nvidia-smi command exists but failed"
  else
    warn "Host nvidia-smi not found in PATH"
  fi
}

run_gpu_smoke_nvidia_smi() {
  local image="$1"
  local mode="$2"
  local -a cmd=(docker run --rm)

  if [[ "${mode}" == "gpus" ]]; then
    cmd+=(--gpus all)
  else
    cmd+=(--runtime=nvidia -e NVIDIA_VISIBLE_DEVICES=all -e NVIDIA_DRIVER_CAPABILITIES=compute,utility)
  fi

  cmd+=("${image}" nvidia-smi)
  "${cmd[@]}" >/dev/null 2>&1
}

run_gpu_smoke_inference_image() {
  local image="$1"
  local mode="$2"
  local -a cmd=(docker run --rm --entrypoint python)

  if [[ "${mode}" == "gpus" ]]; then
    cmd+=(--gpus all)
  else
    cmd+=(--runtime=nvidia -e NVIDIA_VISIBLE_DEVICES=all -e NVIDIA_DRIVER_CAPABILITIES=compute,utility)
  fi

  cmd+=("${image}" -c 'import torch; print(torch.cuda.is_available())')
  "${cmd[@]}" 2>/dev/null | grep -q '^True$'
}

detect_gpu_mode() {
  local mode="none"

  if [[ "${ENABLE_GPU}" != "1" ]]; then
    info "ENABLE_GPU=${ENABLE_GPU}, forcing CPU mode"
    echo "${mode}"
    return 0
  fi

  if ensure_image_or_pull "${CUDA_TEST_IMAGE}"; then
    info "GPU smoke test with CUDA image: ${CUDA_TEST_IMAGE}"
    if run_gpu_smoke_nvidia_smi "${CUDA_TEST_IMAGE}" gpus; then
      echo "gpus"
      return 0
    fi
    if run_gpu_smoke_nvidia_smi "${CUDA_TEST_IMAGE}" runtime; then
      echo "runtime"
      return 0
    fi
    warn "CUDA image smoke test failed for both --gpus all and --runtime=nvidia"
  else
    warn "CUDA test image unavailable: ${CUDA_TEST_IMAGE}"
  fi

  if docker image inspect "${INFERENCE_IMAGE}" >/dev/null 2>&1; then
    info "Fallback GPU smoke test with inference image: ${INFERENCE_IMAGE}"
    if run_gpu_smoke_inference_image "${INFERENCE_IMAGE}" gpus; then
      echo "gpus"
      return 0
    fi
    if run_gpu_smoke_inference_image "${INFERENCE_IMAGE}" runtime; then
      echo "runtime"
      return 0
    fi
    warn "Inference image GPU smoke test failed for both GPU modes"
  else
    warn "Inference image not present locally for fallback smoke test: ${INFERENCE_IMAGE}"
  fi

  error "GPU unavailable: both '--gpus all' and '--runtime=nvidia' smoke tests failed."
  error "Next steps: install/configure nvidia-container-toolkit, verify host driver via nvidia-smi, and check Docker daemon runtime config."
  error "If offline, preload CUDA test image with: docker load < cuda-image.tar (e.g. ${CUDA_TEST_IMAGE})"
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

if [[ "${SKIP_VLLM_BASE_PULL}" != "1" ]] && ! docker image inspect "${VLLM_BASE_IMAGE}" >/dev/null 2>&1; then
  info "Pulling vLLM base image ${VLLM_BASE_IMAGE}"
  retry_docker_pull "${VLLM_BASE_IMAGE}" "${DOCKER_PULL_RETRIES}" "${DOCKER_PULL_RETRY_WAIT}"
fi

info "Building local inference image ${INFERENCE_IMAGE} (no tar/zst bundle)"
docker build \
  --build-arg VLLM_BASE_IMAGE="${VLLM_BASE_IMAGE}" \
  -t "${INFERENCE_IMAGE}" \
  -f "${DEPLOY_DIR}/vllm/Dockerfile" \
  "${DEPLOY_DIR}"

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
remove_container_if_exists "${INFERENCE_CONTAINER_NAME}"
start_inference_container "${GPU_MODE}"
bash "${SCRIPT_DIR}/run_gateway.sh"
bash "${SCRIPT_DIR}/status.sh"

info "GPU detection result: ${GPU_MODE}"
info "Local test ready. Example: curl -H 'Authorization: Bearer ${API_KEY}' http://127.0.0.1:${GATEWAY_PORT}/v1/models"
