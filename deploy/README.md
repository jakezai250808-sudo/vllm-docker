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
- `VLLM_BASE_IMAGE`：vLLM 基础镜像（可改为企业镜像仓库地址）。
- `DOCKER_PULL_RETRIES` / `DOCKER_PULL_RETRY_WAIT`：`docker pull` 重试次数与间隔。
- `SKIP_GATEWAY_PULL` / `SKIP_VLLM_BASE_PULL`：设为 `1` 时跳过拉取，直接使用本地已加载镜像。
- `ZSTD_LEVEL` / `ZSTD_THREADS`：zstd 压缩级别与线程数（`ZSTD_THREADS=0` 表示自动用多核）。
- `MIRROR_PROFILE`：`default` 或 `cn`；设为 `cn` 时自动切换到中国可用镜像源（可被手动变量覆盖）。
- `CN_IMAGE_GATEWAY` / `CN_VLLM_BASE_IMAGE`：`MIRROR_PROFILE=cn` 的默认镜像地址。
- `RELEASE_BUNDLE_MODE`：一体化发布包打包模式，`zst|tar|both`，默认 `zst`（优先体积更小）。
- `RELEASE_BUNDLE_GLOB`：可选通配符；设置后优先于 `RELEASE_BUNDLE_MODE`。

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

该脚本会先创建/复用 Conda 环境（默认 `llm-offline-hf`），并在该环境中安装 `huggingface_hub`，再通过 Python API 下载模型，避免污染系统 Python。

该脚本会：

- 下载 `Qwen/Qwen3-Coder-Next` 到 `deploy/assets/models/Qwen3-Coder-Next`
- 构建 inference 镜像：`corp/qwen3-coder-next-vllm:offline`（支持 `VLLM_BASE_IMAGE` 指定镜像源）
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


## 一体化发布包（服务器无仓库代码）

如果服务器没有本仓库代码，建议在办公电脑执行：

```bash
# 1) 先生成镜像离线包
bash deploy/scripts/build_offline_bundle.sh

# 2) 再生成“一体化发布包”（包含 deploy 目录和 dist 镜像包）
bash deploy/scripts/make_portable_release.sh
```

生成文件：`deploy/dist/llm_offline_release.tar.gz`。

服务器端：

```bash
# 1) 解压
tar -xzf llm_offline_release.tar.gz
cd llm_offline_release

# 2) 首次运行会自动生成 deploy/.env（若不存在），请编辑 API_KEY
./run_on_server.sh

# 3) 编辑完 deploy/.env 后再次执行
./run_on_server.sh
```

`run_on_server.sh` 内部会调用 `deploy/scripts/load_and_run.sh` 完成：解压 `.tar.zst`（若存在）-> `docker load` -> 启动 inference -> 启动 gateway。

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

### huggingface_hub 缺失

如果遇到报错：

```text
ModuleNotFoundError: No module named 'huggingface_hub'
```

新版 `build_offline_bundle.sh` 不再向系统 Python 安装依赖，而是使用 Conda 隔离环境：

```bash
conda create -y -n llm-offline-hf python=3.10
conda run -n llm-offline-hf python -m pip install huggingface_hub
```

如果公司环境禁用了 conda/pip 出网，请让管理员在内网镜像源中预装该依赖，或将 wheel 包离线导入该 conda 环境。

说明：`huggingface_hub>=1.x` 已使用 `hf` 命令并逐步替代 `huggingface-cli`；本项目脚本已改为直接调用 Python API（`snapshot_download`），不再依赖具体 CLI 名称。


### inference 日志提示 `exec: python: not found`

说明镜像内只有 `python3`（没有 `python` 软链接）或 Python 不在 PATH。当前版本入口脚本会自动优先使用 `python3`，再回退 `python`。

若仍报错，请检查镜像版本是否为最新并重新构建离线包：

```bash
bash deploy/scripts/build_offline_bundle.sh
```

### inference 容器反复 Restarting (127)

常见原因是容器入口脚本解释器不兼容（例如镜像里没有 `bash`）。当前版本已改为 POSIX `sh` 入口脚本。若仍失败，请先查看：

```bash
docker logs --tail 200 inference
docker inspect inference --format '{{.State.ExitCode}}'
```

如果 ExitCode 仍是 `127`，通常是命令不存在；请确认镜像构建是否使用了最新仓库内容并重新构建离线包。

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


### Docker Hub 拉取超时（Gateway Time-out）

如果遇到：

```text
Get "https://registry-1.docker.io/v2/": Gateway Time-out
```

建议按优先级处理：

1. 增加重试（脚本已内置）并调大参数：

```bash
export DOCKER_PULL_RETRIES=6
export DOCKER_PULL_RETRY_WAIT=20
```

2. 使用企业镜像源替代默认镜像：

```bash
export VLLM_BASE_IMAGE=<your-mirror>/vllm/vllm-openai:latest
export IMAGE_GATEWAY=<your-mirror>/nginx:stable
```

3. 预加载镜像并跳过拉取：

```bash
docker load -i preloaded_images.tar
export SKIP_GATEWAY_PULL=1
export SKIP_VLLM_BASE_PULL=1
```

4. 若公司网络策略要求代理，先配置 `HTTP_PROXY/HTTPS_PROXY` 给 Docker daemon。


### 中国可用镜像源（建议）

如果办公电脑访问 Docker Hub 不稳定，可直接启用中国镜像配置：

```bash
export MIRROR_PROFILE=cn
bash deploy/scripts/build_offline_bundle.sh
```

默认会切到：

- `docker.m.daocloud.io/library/nginx:stable`
- `docker.m.daocloud.io/vllm/vllm-openai:latest`

如果你们公司有自建镜像仓库，建议显式覆盖：

```bash
export IMAGE_GATEWAY=<your-registry>/library/nginx:stable
export VLLM_BASE_IMAGE=<your-registry>/vllm/vllm-openai:latest
```


### zstd 压缩加速（多核）

默认已支持多核压缩，可通过环境变量调整：

```bash
export ZSTD_THREADS=0   # 0=自动使用全部可用 CPU 线程
export ZSTD_LEVEL=15    # 降低压缩级别可显著提速
bash deploy/scripts/build_offline_bundle.sh
```

说明：压缩级别越高体积更小但更慢（默认 19）。


### 反复打包速度优化（dist 目录大文件）

`make_portable_release.sh` 默认只打入 `*.tar.zst`（`RELEASE_BUNDLE_MODE=zst`），避免把历史 `llm_offline_release.tar.gz`、旧 tar 包反复再打包。

可配置模式：

```bash
export RELEASE_BUNDLE_MODE=zst   # 默认：仅 *.tar.zst
# export RELEASE_BUNDLE_MODE=tar # 仅 *.tar
# export RELEASE_BUNDLE_MODE=both # 同时打 *.tar.zst 和 *.tar
bash deploy/scripts/make_portable_release.sh
```

也可按通配符精确选择（优先级高于模式）：

```bash
export RELEASE_BUNDLE_GLOB='qwen3_coder_next_stack.tar.zst'
bash deploy/scripts/make_portable_release.sh
```

如需清理历史文件进一步提速：

```bash
find deploy/dist -maxdepth 1 -type f \( -name '*.tar.gz' -o -name '*.old' \) -delete
```

