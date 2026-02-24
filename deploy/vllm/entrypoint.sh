#!/bin/sh
set -eu

TP="${TP:-2}"
PORT="${PORT:-8000}"
MAX_MODEL_LEN="${MAX_MODEL_LEN:-65536}"
DTYPE="${DTYPE:-auto}"
EXTRA_ARGS="${EXTRA_ARGS:-}"

echo "Starting vLLM OpenAI API server with model /models/Qwen3-Coder-Next"

# shellcheck disable=SC2086
exec python -m vllm.entrypoints.openai.api_server \
  --model /models/Qwen3-Coder-Next \
  --port "${PORT}" \
  --tensor-parallel-size "${TP}" \
  --max-model-len "${MAX_MODEL_LEN}" \
  --dtype "${DTYPE}" \
  ${EXTRA_ARGS}
