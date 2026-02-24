#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/common.sh"

require_docker

print_summary

echo "\n[docker ps]"
docker ps --filter "name=${INFERENCE_CONTAINER_NAME}" --filter "name=${GATEWAY_CONTAINER_NAME}" --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'

echo "\n[network inspect ${NETWORK_NAME}]"
if docker network inspect "${NETWORK_NAME}" >/dev/null 2>&1; then
  docker network inspect "${NETWORK_NAME}" --format '{{json .Containers}}'
else
  echo "network not found"
fi

echo "\n[health status]"
for c in "${INFERENCE_CONTAINER_NAME}" "${GATEWAY_CONTAINER_NAME}"; do
  if docker inspect "${c}" >/dev/null 2>&1; then
    docker inspect "${c}" --format "${c}: {{if .State.Health}}{{.State.Health.Status}}{{else}}no-healthcheck{{end}}"
  else
    echo "${c}: not found"
  fi
done
