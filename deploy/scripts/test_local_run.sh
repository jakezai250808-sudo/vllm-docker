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
ensure_network

if [[ "${SKIP_GATEWAY_PULL}" != "1" ]] && ! docker image inspect "${IMAGE_GATEWAY}" >/dev/null 2>&1; then
  log "Pulling gateway image ${IMAGE_GATEWAY}"
  retry_docker_pull "${IMAGE_GATEWAY}" "${DOCKER_PULL_RETRIES}" "${DOCKER_PULL_RETRY_WAIT}"
fi

if [[ "${SKIP_VLLM_BASE_PULL}" != "1" ]] && ! docker image inspect "${VLLM_BASE_IMAGE}" >/dev/null 2>&1; then
  log "Pulling vLLM base image ${VLLM_BASE_IMAGE}"
  retry_docker_pull "${VLLM_BASE_IMAGE}" "${DOCKER_PULL_RETRIES}" "${DOCKER_PULL_RETRY_WAIT}"
fi

log "Building local inference image ${IMAGE_INFERENCE} (no tar/zst bundle)"
docker build \
  --build-arg VLLM_BASE_IMAGE="${VLLM_BASE_IMAGE}" \
  -t "${IMAGE_INFERENCE}" \
  -f "${DEPLOY_DIR}/vllm/Dockerfile" \
  "${DEPLOY_DIR}"

if [[ "${RUN_STACK}" != "1" ]]; then
  log "RUN_STACK=${RUN_STACK}, build finished and skip starting containers"
  exit 0
fi

if [[ -z "${API_KEY:-}" ]]; then
  export API_KEY="${LOCAL_TEST_API_KEY:-local-test-key}"
  log "API_KEY not set, using LOCAL_TEST_API_KEY for local smoke test"
fi

if [[ -z "${ENABLE_GPU:-}" ]]; then
  export ENABLE_GPU=0
  log "ENABLE_GPU not set, default to CPU smoke test (ENABLE_GPU=0)"
fi

bash "${SCRIPT_DIR}/run_inference.sh"
bash "${SCRIPT_DIR}/run_gateway.sh"
bash "${SCRIPT_DIR}/status.sh"

log "Local test ready. Example: curl -H 'Authorization: Bearer ${API_KEY}' http://127.0.0.1:${GATEWAY_PORT}/v1/models"
