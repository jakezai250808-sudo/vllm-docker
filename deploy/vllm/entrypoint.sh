#!/bin/sh
set -eu

MODEL_PATH="${MODEL_PATH:-/models/Qwen3-Coder-Next}"
TP="${TP:-1}"
PORT="${PORT:-8000}"
MAX_MODEL_LEN="${MAX_MODEL_LEN:-4096}"
DTYPE="${DTYPE:-auto}"
EXTRA_ARGS="${EXTRA_ARGS:-}"

if [ "$#" -gt 0 ]; then
  exec "$@"
fi

if command -v python3 >/dev/null 2>&1; then
  PYTHON_BIN="python3"
elif command -v python >/dev/null 2>&1; then
  PYTHON_BIN="python"
else
  echo "Neither python3 nor python was found in container PATH." >&2
  exit 127
fi

echo "Starting vLLM OpenAI API server: model=${MODEL_PATH}, tp=${TP}, max_model_len=${MAX_MODEL_LEN}, dtype=${DTYPE}, port=${PORT}"

# shellcheck disable=SC2086
exec "${PYTHON_BIN}" -m vllm.entrypoints.openai.api_server \
  --model "${MODEL_PATH}" \
  --port "${PORT}" \
  --tensor-parallel-size "${TP}" \
  --max-model-len "${MAX_MODEL_LEN}" \
  --dtype "${DTYPE}" \
  ${EXTRA_ARGS}
