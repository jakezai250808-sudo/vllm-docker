#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/common.sh"

TP="${TP:-2}"
PORT="${INFERENCE_PORT:-8000}"
MAX_MODEL_LEN="${MAX_MODEL_LEN:-65536}"
DTYPE="${DTYPE:-auto}"
CUDA_VISIBLE_DEVICES="${CUDA_VISIBLE_DEVICES:-}"
EXTRA_ARGS="${EXTRA_ARGS:-}"

require_docker
ensure_network
ensure_image "${IMAGE_INFERENCE}"
remove_container_if_exists "${INFERENCE_CONTAINER_NAME}"

GPU_ARGS=(--gpus all)
if [[ -n "${CUDA_VISIBLE_DEVICES}" ]]; then
  GPU_ARGS+=( -e "CUDA_VISIBLE_DEVICES=${CUDA_VISIBLE_DEVICES}" )
fi

log "Starting inference container ${INFERENCE_CONTAINER_NAME} using image ${IMAGE_INFERENCE}"
docker run -d --restart unless-stopped \
  --name "${INFERENCE_CONTAINER_NAME}" \
  --network "${NETWORK_NAME}" \
  "${GPU_ARGS[@]}" \
  -e TP="${TP}" \
  -e PORT="${PORT}" \
  -e MAX_MODEL_LEN="${MAX_MODEL_LEN}" \
  -e DTYPE="${DTYPE}" \
  -e EXTRA_ARGS="${EXTRA_ARGS}" \
  --health-cmd='python -c "import urllib.request; urllib.request.urlopen(\"http://127.0.0.1:8000/v1/models\", timeout=5)"' \
  --health-interval=30s \
  --health-timeout=10s \
  --health-retries=5 \
  --health-start-period=120s \
  "${IMAGE_INFERENCE}"

log "Inference started. Check logs: docker logs -f ${INFERENCE_CONTAINER_NAME}"
