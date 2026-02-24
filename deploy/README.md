# Offline deployment (no Docker Compose): Nginx Gateway + vLLM

本方案适用于企业内网离线部署：只依赖 `docker network` + `docker run` + shell 脚本，不需要 `docker compose` / `docker-compose`。

## 目录结构

```text
deploy/
├── .env.example
├── README.md
├── assets/
│   └── models/
│       └── Qwen3-Coder-Next/          # build_offline_bundle.sh 下载到这里
├── dist/                              # 离线镜像包输出目录
├── generated/
│   └── nginx.conf                     # run_gateway.sh 渲染输出
├── nginx/
│   └── nginx.conf.template
├── scripts/
│   ├── build_offline_bundle.sh
│   ├── common.sh
│   ├── load_and_run.sh
│   ├── run_gateway.sh
│   ├── run_inference.sh
│   ├── status.sh
│   └── stop_all.sh
└── vllm/
    ├── Dockerfile
    └── entrypoint.sh
```

## 环境变量

复制并修改：

```bash
cp deploy/.env.example deploy/.env
```

关键变量：

- `API_KEY`：必须设置，网关鉴权使用 `Authorization: Bearer <API_KEY>`。
- `GATEWAY_PORT`：默认 `8080`，唯一对外暴露端口。
- `MAX_BODY_SIZE`：默认 `50m`。
- `TP` / `MAX_MODEL_LEN` / `DTYPE`：vLLM 启动参数。
- `CUDA_VISIBLE_DEVICES`：可空，用于限制 GPU。
- `IMAGE_INFERENCE` / `IMAGE_GATEWAY`：镜像名。
- `ENABLE_RATE_LIMIT`：`off`（默认）或 `on`。
- `HF_CONDA_ENV` / `HF_CONDA_PYTHON`：离线打包时用于下载模型的 Conda 隔离环境参数。

## 安全策略

### 1) IP allowlist（Nginx）

默认允许：

- `10.0.0.0/8`
- `172.16.0.0/12`
- `192.168.0.0/16`
- `10.8.0.0/24`（示例 VPN 段）

修改方式：编辑 `deploy/nginx/nginx.conf.template` 中 `allow` / `deny` 规则后重启网关。

### 2) API Key 鉴权

请求头必须严格匹配：

```http
Authorization: Bearer <API_KEY>
```

否则返回 `401`。

## 离线交付流程

## A. 办公电脑（可出网）

1. 配置代理（如需）：

```bash
export http_proxy=http://proxy.corp.local:7890
export https_proxy=http://proxy.corp.local:7890
```

2. 执行打包：

```bash
bash deploy/scripts/build_offline_bundle.sh
```

该脚本会先创建/复用 Conda 环境（默认 `llm-offline-hf`），并在该环境中安装 `huggingface_hub[cli]`，避免污染系统 Python。

该脚本会：

- 下载 `Qwen/Qwen3-Coder-Next` 到 `deploy/assets/models/Qwen3-Coder-Next`
- 构建 inference 镜像：`corp/qwen3-coder-next-vllm:offline`
- 拉取 nginx 镜像：`nginx:stable`
- `docker save` 输出到 `deploy/dist/qwen3_coder_next_stack.tar`
- 若系统有 `zstd`，额外生成 `.tar.zst`

## B. 服务器（无外网）

1. 传输离线包（示例）：

```bash
scp deploy/dist/qwen3_coder_next_stack.tar* user@server:/opt/vllm-docker/deploy/dist/
# 或 rsync -avP deploy/dist/ user@server:/opt/vllm-docker/deploy/dist/
```

2. 配置环境变量：

```bash
cp deploy/.env.example deploy/.env
# 编辑 deploy/.env，至少改 API_KEY
```

3. 加载并启动：

```bash
bash deploy/scripts/load_and_run.sh
```

该脚本会自动：`docker load` -> 启动 inference -> 启动 gateway -> 打印状态。

## 运维命令

```bash
# 启动推理
bash deploy/scripts/run_inference.sh

# 启动网关
bash deploy/scripts/run_gateway.sh

# 查看状态
bash deploy/scripts/status.sh

# 停止并删除容器
bash deploy/scripts/stop_all.sh
```

## 健康检查与调用示例

### 健康检查

```bash
# 通过网关检查（推荐）
curl -i -H "Authorization: Bearer ${API_KEY}" http://<SERVER_IP>:8080/v1/models

# 在网关容器里检查 inference 联通性
docker exec -it llm-gateway wget -qO- http://inference:8000/v1/models
```

### OpenAI 兼容调用

```bash
curl http://<SERVER_IP>:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${API_KEY}" \
  -d '{
    "model": "Qwen/Qwen3-Coder-Next",
    "messages": [{"role":"user","content":"写一个 Python 快排"}],
    "temperature": 0.2
  }'
```

## 常见故障排查

### 401 Unauthorized

- 未带 `Authorization` 或格式不对。
- `Bearer` 后的 key 与 `API_KEY` 不一致。
- 检查：`docker logs llm-gateway`。

### 403 Forbidden

- 客户端 IP 不在 allowlist。
- 修改 `deploy/nginx/nginx.conf.template` allow 规则后，重启 gateway：

```bash
bash deploy/scripts/run_gateway.sh
```

### huggingface-cli / huggingface_hub 缺失

如果遇到报错：

```text
from huggingface_hub.commands.huggingface_cli import main
ModuleNotFoundError: No module named 'huggingface_hub'
```

新版 `build_offline_bundle.sh` 不再向系统 Python 安装依赖，而是使用 Conda 隔离环境：

```bash
conda create -y -n llm-offline-hf python=3.10
conda run -n llm-offline-hf python -m pip install "huggingface_hub[cli]"
```

如果公司环境禁用了 conda/pip 出网，请让管理员在内网镜像源中预装该依赖，或将 wheel 包离线导入该 conda 环境。

### 502 Bad Gateway

- inference 未启动或尚未 ready。
- 查看：

```bash
docker logs -f inference
docker inspect inference --format '{{json .State.Health}}'
```

### GPU 不可见 / 启动失败

- 确认宿主机已安装 NVIDIA 驱动与 nvidia-container-toolkit。
- 检查：

```bash
docker run --rm --gpus all nvidia/cuda:12.2.0-base-ubuntu22.04 nvidia-smi
```

### 容器网络问题

```bash
docker network inspect llm-net
docker exec -it llm-gateway getent hosts inference
```

### 查看日志

```bash
docker logs -f inference
docker logs -f llm-gateway
```
