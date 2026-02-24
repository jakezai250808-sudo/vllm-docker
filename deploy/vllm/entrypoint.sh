#!/bin/sh
set -eu

TP="${TP:-2}"
PORT="${PORT:-8000}"
MAX_MODEL_LEN="${MAX_MODEL_LEN:-65536}"
DTYPE="${DTYPE:-auto}"
EXTRA_ARGS="${EXTRA_ARGS:-}"

if command -v python3 >/dev/null 2>&1; then
  PYTHON_BIN="python3"
elif command -v python >/dev/null 2>&1; then
  PYTHON_BIN="python"
else
  echo "Neither python3 nor python was found in container PATH." >&2
  exit 127
fi

echo "Starting vLLM OpenAI API server with model /models/Qwen3-Coder-Next (python=${PYTHON_BIN})"

# shellcheck disable=SC2086
exec "${PYTHON_BIN}" -m vllm.entrypoints.openai.api_server \
  --model /models/Qwen3-Coder-Next \
  --port "${PORT}" \
  --tensor-parallel-size "${TP}" \
  --max-model-len "${MAX_MODEL_LEN}" \
  --dtype "${DTYPE}" \
  ${EXTRA_ARGS}
