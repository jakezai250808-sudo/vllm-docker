FROM vllm/vllm-openai:latest

WORKDIR /app

COPY deploy/assets/models/Qwen3-Coder-Next /models/Qwen3-Coder-Next
COPY deploy/vllm/entrypoint.sh /entrypoint.sh

RUN chmod +x /entrypoint.sh

EXPOSE 8000

ENTRYPOINT ["/entrypoint.sh"]
