#!/usr/bin/env bash
set -euo pipefail

TP="${TP:-2}"
MAX_MODEL_LEN="${MAX_MODEL_LEN:-65536}"
DTYPE="${DTYPE:-auto}"
PORT="${PORT:-8000}"
MODEL_PATH="/models/Qwen3-Coder-Next"

if [[ ! -d "${MODEL_PATH}" ]]; then
  echo "[ERROR] model path not found: ${MODEL_PATH}" >&2
  exit 1
fi

echo "[INFO] Starting vLLM with model=${MODEL_PATH}, TP=${TP}, MAX_MODEL_LEN=${MAX_MODEL_LEN}, DTYPE=${DTYPE}, PORT=${PORT}"

exec python3 -m vllm.entrypoints.openai.api_server \
  --host 0.0.0.0 \
  --port "${PORT}" \
  --model "${MODEL_PATH}" \
  --tensor-parallel-size "${TP}" \
  --max-model-len "${MAX_MODEL_LEN}" \
  --dtype "${DTYPE}" \
  --served-model-name "Qwen3-Coder-Next"
