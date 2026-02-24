FROM nvidia/cuda:12.4.1-cudnn-runtime-ubuntu22.04

ENV DEBIAN_FRONTEND=noninteractive \
    PIP_NO_CACHE_DIR=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

RUN apt-get update && apt-get install -y --no-install-recommends \
    python3 python3-pip python3-venv curl ca-certificates && \
    rm -rf /var/lib/apt/lists/*

RUN python3 -m pip install --upgrade pip && \
    python3 -m pip install "vllm>=0.6.0" "transformers>=4.45.0"

WORKDIR /app

# 将办公电脑预下载好的模型拷贝进镜像，供离线环境使用
COPY deploy/assets/models/Qwen3-Coder-Next /models/Qwen3-Coder-Next
COPY deploy/vllm/entrypoint.sh /app/entrypoint.sh

RUN chmod +x /app/entrypoint.sh

EXPOSE 8000

HEALTHCHECK --interval=30s --timeout=10s --retries=10 --start-period=120s \
  CMD curl -fsS http://127.0.0.1:${PORT:-8000}/v1/models >/dev/null || exit 1

ENTRYPOINT ["/app/entrypoint.sh"]
