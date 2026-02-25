ARG VLLM_BASE_IMAGE=vllm/vllm-openai:latest
FROM ${VLLM_BASE_IMAGE}

WORKDIR /app

COPY assets/models/Qwen3-Coder-Next /models/Qwen3-Coder-Next
COPY vllm/entrypoint.sh /entrypoint.sh

RUN chmod +x /entrypoint.sh

EXPOSE 8000

ENTRYPOINT ["/entrypoint.sh"]
