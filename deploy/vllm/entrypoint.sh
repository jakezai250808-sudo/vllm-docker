#!/usr/bin/env bash
set -euo pipefail

TP="${TP:-2}"
PORT="${PORT:-8000}"
MAX_MODEL_LEN="${MAX_MODEL_LEN:-65536}"
DTYPE="${DTYPE:-auto}"
EXTRA_ARGS="${EXTRA_ARGS:-}"

CMD=(python -m vllm.entrypoints.openai.api_server
  --model /models/Qwen3-Coder-Next
  --port "${PORT}"
  --tensor-parallel-size "${TP}"
  --max-model-len "${MAX_MODEL_LEN}"
  --dtype "${DTYPE}")

if [[ -n "${EXTRA_ARGS}" ]]; then
  # shellcheck disable=SC2206
  extra_parts=(${EXTRA_ARGS})
  CMD+=("${extra_parts[@]}")
fi

echo "Starting vLLM OpenAI API server with model /models/Qwen3-Coder-Next"
exec "${CMD[@]}"
