#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
DEPLOY_DIR=$(cd "${SCRIPT_DIR}/.." && pwd)

TAR_PATH="${DEPLOY_DIR}/dist/qwen3_coder_next_stack.tar"
ENV_FILE="${DEPLOY_DIR}/.env"
COMPOSE_FILE="${DEPLOY_DIR}/docker-compose.yml"

if [[ ! -f "${TAR_PATH}" ]]; then
  echo "[ERROR] 离线镜像包不存在: ${TAR_PATH}" >&2
  exit 1
fi

if [[ ! -f "${ENV_FILE}" ]]; then
  echo "[ERROR] 环境变量文件不存在: ${ENV_FILE}" >&2
  echo "请先 cp deploy/.env.example deploy/.env 并修改参数" >&2
  exit 1
fi

echo "[1/3] 加载离线镜像包..."
docker load -i "${TAR_PATH}"

echo "[2/3] 启动服务..."
docker compose -f "${COMPOSE_FILE}" --env-file "${ENV_FILE}" up -d

echo "[3/3] 服务状态："
docker compose -f "${COMPOSE_FILE}" --env-file "${ENV_FILE}" ps

echo "\n完成。可先执行：docker compose -f ${COMPOSE_FILE} --env-file ${ENV_FILE} logs -f gateway"
