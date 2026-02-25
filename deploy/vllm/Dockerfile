FROM nvidia/cuda:12.1.0-runtime-ubuntu22.04

ARG HTTP_PROXY=http://127.0.0.1:3128
ARG HTTPS_PROXY=http://127.0.0.1:3128
ARG NO_PROXY=127.0.0.1,localhost

ENV http_proxy=${HTTP_PROXY} \
    https_proxy=${HTTPS_PROXY} \
    no_proxy=${NO_PROXY} \
    HTTP_PROXY=${HTTP_PROXY} \
    HTTPS_PROXY=${HTTPS_PROXY} \
    NO_PROXY=${NO_PROXY}

ENV DEBIAN_FRONTEND=noninteractive \
    PIP_NO_CACHE_DIR=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends \
    python3.10 \
    python3-pip \
    python3-dev \
    ca-certificates \
    curl \
    && rm -rf /var/lib/apt/lists/*

RUN python3 -m pip install --upgrade pip setuptools wheel

# Pin torch to CUDA 12.1 wheels to avoid drifting to cu124.
RUN python3 -m pip install \
    --index-url https://download.pytorch.org/whl/cu121 \
    torch==2.3.1+cu121 torchvision==0.18.1+cu121 torchaudio==2.3.1+cu121

# Pin a stable vLLM release (no nightly).
RUN python3 -m pip install vllm==0.5.1 transformers==4.42.4 lm-format-enforcer==0.10.6

# Build-time self-checks to ensure image stays on CUDA 12.1 and expected vLLM.
RUN python3 -c "import torch; print(torch.__version__, torch.version.cuda); assert torch.version.cuda and torch.version.cuda.startswith('12.1')"
RUN python3 -c "import vllm; print(vllm.__version__)"
RUN python3 -c "from transformers.generation.logits_process import LogitsWarper, PrefixConstrainedLogitsProcessor; print('transformers-logits-ok')"

COPY models/Qwen3-Coder-Next /models/Qwen3-Coder-Next
COPY entrypoint.sh /entrypoint.sh

RUN chmod +x /entrypoint.sh

EXPOSE 8000

ENTRYPOINT ["/entrypoint.sh"]
