#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DEPLOY_DIR="${ROOT_DIR}/deploy"
ENV_FILE="${DEPLOY_DIR}/.env"

if [[ -f "${ENV_FILE}" ]]; then
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
fi

NETWORK_NAME="${NETWORK_NAME:-llm-net}"
INFERENCE_CONTAINER_NAME="${INFERENCE_CONTAINER_NAME:-inference}"
GATEWAY_CONTAINER_NAME="${GATEWAY_CONTAINER_NAME:-llm-gateway}"
IMAGE_INFERENCE="${IMAGE_INFERENCE:-corp/qwen3-coder-next-vllm:offline}"
IMAGE_GATEWAY="${IMAGE_GATEWAY:-nginx:stable}"
INFERENCE_PORT="${INFERENCE_PORT:-8000}"
GATEWAY_PORT="${GATEWAY_PORT:-8080}"
MAX_BODY_SIZE="${MAX_BODY_SIZE:-50m}"
PROXY_CONNECT_TIMEOUT="${PROXY_CONNECT_TIMEOUT:-30s}"
PROXY_READ_TIMEOUT="${PROXY_READ_TIMEOUT:-600s}"
PROXY_SEND_TIMEOUT="${PROXY_SEND_TIMEOUT:-600s}"
LIMIT_REQ_RATE="${LIMIT_REQ_RATE:-20r/s}"
LIMIT_REQ_BURST="${LIMIT_REQ_BURST:-40}"
ENABLE_RATE_LIMIT="${ENABLE_RATE_LIMIT:-off}"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Missing required command: $cmd" >&2
    exit 1
  fi
}

require_docker() {
  require_cmd docker
  docker version >/dev/null
}

ensure_network() {
  if ! docker network inspect "${NETWORK_NAME}" >/dev/null 2>&1; then
    log "Creating docker network ${NETWORK_NAME}"
    docker network create "${NETWORK_NAME}" >/dev/null
  fi
}

ensure_image() {
  local image="$1"
  if ! docker image inspect "${image}" >/dev/null 2>&1; then
    echo "Docker image not found: ${image}" >&2
    exit 1
  fi
}

remove_container_if_exists() {
  local container="$1"
  if docker ps -a --format '{{.Names}}' | grep -Fx "${container}" >/dev/null 2>&1; then
    log "Removing existing container ${container}"
    docker rm -f "${container}" >/dev/null
  fi
}

print_summary() {
  log "network=${NETWORK_NAME} inference_container=${INFERENCE_CONTAINER_NAME} gateway_container=${GATEWAY_CONTAINER_NAME}"
}
