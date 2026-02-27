# Offline deployment (no Docker Compose): Nginx Gateway + vLLM (cu121)

本方案用于企业内网离线部署，保持 `docker run` + shell 脚本方式，不使用 Docker Compose。

> 关键兼容结论：宿主机 NVIDIA Driver 530.x（`nvidia-smi` 显示 CUDA 12.1）应使用 **cu121** 推理镜像。
> 若使用 cu124 镜像，常见报错为：`nvidia-container-cli: requirement error: unsatisfied condition: cuda>=12.4`。

## 为什么改为 cu121

- 530.x 驱动可稳定运行 CUDA 12.1 容器。
- 本仓库推理镜像默认改为：`corp/qwen3-coder-next-vllm:cu121`。
- 不需要升级 Ubuntu，也不需要在宿主机安装 CUDA Toolkit；只需驱动 + nvidia-container-toolkit 正常。

## 目录结构

```text
deploy/
├── .env.example
├── README.md
├── assets/
│   └── models/
│       └── Qwen3-Coder-Next/
├── dist/
├── nginx/
│   └── nginx.conf.template
├── scripts/
│   ├── build_offline_bundle.sh
│   ├── load_and_run.sh
│   ├── run_gateway.sh
│   ├── run_inference.sh
│   ├── status.sh
│   ├── stop_all.sh
│   └── test_local_run.sh
└── vllm/
    ├── Dockerfile
    └── entrypoint.sh
```

## 默认参数（已调优为办公电脑可启动优先）

- `IMAGE_INFERENCE=corp/qwen3-coder-next-vllm:cu121`
- `TP=1`
- `MAX_MODEL_LEN=4096`

说明：RTX 5000 16GB 机器建议只做“服务可启动/接口可用”验证；正式高并发推理建议在 A100 服务器承担。

## 环境变量

```bash
cp deploy/.env.example deploy/.env
```

关键项：

- `API_KEY`：网关鉴权密钥（必填）
- `IMAGE_INFERENCE`：默认 `corp/qwen3-coder-next-vllm:cu121`
- `TP` / `MAX_MODEL_LEN` / `DTYPE`
- `ENABLE_GPU`：默认 `1`，设 `0` 可强制 CPU
- `CUDA_VISIBLE_DEVICES`：可选，用于限制可见卡
- `SKIP_GATEWAY_PULL`：设 `1` 时不拉取 nginx，使用本地镜像

## 验收清单（必须执行）

### 1) 构建 cu121 推理镜像

```bash
docker build -t corp/qwen3-coder-next-vllm:cu121 -f deploy/vllm/Dockerfile deploy/vllm
```

### 2) GPU 验证（不应再出现 `cuda>=12.4`）

```bash
docker run --rm --gpus all corp/qwen3-coder-next-vllm:cu121 python -c "import torch; print(torch.version.cuda)"
```

预期输出以 `12.1` 开头。

### 3) 启动 API（OpenAI 兼容）

```bash
docker run --rm --gpus all -p 8000:8000 -e TP=1 -e MAX_MODEL_LEN=4096 corp/qwen3-coder-next-vllm:cu121
curl http://localhost:8000/v1/models
```

> 若显存不足（OOM），请继续下调参数（例如更低 `MAX_MODEL_LEN`），这属于容量问题，不是 CUDA/驱动兼容问题。

### 4) 离线打包（包含 nginx + inference:cu121）

```bash
bash deploy/scripts/build_offline_bundle.sh
# 输出：deploy/dist/qwen3_coder_next_stack.tar(.zst)
```

脚本会将 `IMAGE_INFERENCE`（默认 cu121）与 `IMAGE_GATEWAY` 一起 `docker save` 到 bundle。

### 5) 服务器侧（无外网）

```bash
# 先把 tar/tar.zst 传到服务器 deploy/dist/
bash deploy/scripts/load_and_run.sh
```

`load_and_run.sh` 只做 `docker load` + `docker run`，不依赖服务器侧 `docker pull`。





## 网络代理约定（新增）

当脚本需要访问网络时（例如 `docker pull`、`pip`、`huggingface_hub`），默认使用：

- `http_proxy=http://127.0.0.1:3128`
- `https_proxy=http://127.0.0.1:3128`

脚本从 `deploy/scripts/common.sh` 统一注入该默认值；如果你已在环境里手动设置了代理变量，则会保留你的设置（不会覆盖）。

可选覆盖：

```bash
export DEFAULT_PROXY_URL=http://127.0.0.1:3128
# 或者显式设置 http_proxy/https_proxy
```

## 构建 Claude Code 客户端镜像（新增）

新增脚本：`deploy/scripts/build_claude_code_image.sh`

```bash
bash deploy/scripts/build_claude_code_image.sh
```

可选参数：

```bash
CLAUDE_IMAGE=corp/claude-code-client:latest \
CLAUDE_BASE_IMAGE=node:20 \
CLAUDE_NPM_PACKAGE=@anthropic-ai/claude-code \
CLAUDE_BIN=claude \
CLAUDE_NPM_REGISTRY=https://registry.npmmirror.com \
SAVE_IMAGE_TAR=1 \
  bash deploy/scripts/build_claude_code_image.sh
```

- `SAVE_IMAGE_TAR=1` 时会输出 `deploy/dist/claude_code_client.tar`（有 `zstd` 则同时生成 `.zst`）。

- 脚本会优先复用本地已有 `CLAUDE_BASE_IMAGE`，仅在本地缺失时才执行 `docker pull`。

- 可通过 `CLAUDE_NPM_REGISTRY` 传入 npm registry；构建日志会打印 `[claude-build] npm registry=...` 以确认是否生效。

## 安装最新版本 IDE（Java + CLion）（新增）

新增脚本：`deploy/scripts/install_latest_ide.sh`

### 预览将执行命令（不安装）

```bash
bash deploy/scripts/install_latest_ide.sh --dry-run
```

### 实际安装（Ubuntu）

```bash
sudo bash deploy/scripts/install_latest_ide.sh
```

默认行为：

- 安装 Java：`openjdk-21-jdk`
- 安装 IntelliJ IDEA Ultimate（商业版，snap，`stable` channel）
- 安装 CLion（snap，`stable` channel）

可选参数示例：

```bash
sudo JAVA_PACKAGE=openjdk-17-jdk IDEA_CHANNEL=latest/stable CLION_CHANNEL=latest/stable \
  bash deploy/scripts/install_latest_ide.sh
```

若你的环境无法连接 Snap Store（如报“无法连接 snap 商店”），脚本默认会告警并跳过 IDE 安装（不会整体失败）。

```bash
sudo ALLOW_SNAP_FAILURE=1 bash deploy/scripts/install_latest_ide.sh
```

若你希望连接失败时直接报错退出：

```bash
sudo ALLOW_SNAP_FAILURE=0 bash deploy/scripts/install_latest_ide.sh
```

若只安装 CLion（跳过 IDEA）：

```bash
sudo INSTALL_INTELLIJ_IDEA=0 bash deploy/scripts/install_latest_ide.sh
```

## 主机 GPU/驱动环境检测与安装脚本（新增）

新增脚本：`deploy/scripts/setup_nvidia_host.sh`

### 仅检测（推荐先执行）

```bash
bash deploy/scripts/setup_nvidia_host.sh
```

### 自动安装（Ubuntu，需 root）

支持 `--dry-run`（只打印将执行命令，不真正安装）：

```bash
bash deploy/scripts/setup_nvidia_host.sh --mode install --dry-run
```

> `--dry-run` 仅预览命令，不会真正安装；因此输出中的驱动/runtime状态仍是“当前主机现状”。


```bash
sudo MODE=install INSTALL_NVIDIA_TOOLKIT=1 INSTALL_NVIDIA_DRIVER=0 \
  bash deploy/scripts/setup_nvidia_host.sh
```

可选：安装指定驱动包（例如 550）：

```bash
sudo MODE=install INSTALL_NVIDIA_DRIVER=1 NVIDIA_DRIVER_PACKAGE=nvidia-driver-550 \
  bash deploy/scripts/setup_nvidia_host.sh
```

> 说明：驱动升级后通常需要重启；脚本会提示执行 `nvidia-smi` 和 Docker `--gpus all` 验证命令。

## 下载适合 RTX 5000 的小模型（新增）

如果你只想先做功能联通验证（避免大模型占满 16GB 显存），可以先下载小模型：

```bash
bash deploy/scripts/download_small_model.sh
```

默认会下载：`Qwen/Qwen2.5-1.5B-Instruct`，并同步到：

- `deploy/assets/models/Qwen2.5-1.5B-Instruct`
- `deploy/vllm/models/Qwen2.5-1.5B-Instruct`

启动时可指向该模型目录（vLLM entrypoint 支持 `MODEL_PATH`）：

```bash
docker run --rm --gpus all -p 8000:8000 \
  -e MODEL_PATH=/models/Qwen2.5-1.5B-Instruct \
  -e TP=1 -e MAX_MODEL_LEN=4096 \
  corp/qwen3-coder-next-vllm:cu121
```

## 本机一键验证（构建+探测+启动）

```bash
bash deploy/scripts/test_local_run.sh
```

该脚本会：

- 先做真实 GPU smoke test（`--gpus all`，失败再试 `--runtime=nvidia`）
- 输出 `GPU_MODE=gpus|runtime|none`
- 按 `GPU_MODE` 自动选择 inference 启动参数

## 常见问题

### 出现 `unsatisfied condition: cuda>=12.4`

含义：镜像依赖 cu124，但宿主机驱动版本不足。处理方式：

1. 使用本仓库默认 cu121 镜像（推荐）
2. 或升级 NVIDIA 驱动以满足 cu124

不需要升级 Ubuntu，也不需要在宿主机安装 CUDA Toolkit。

### 宿主机 GPU 通道自检

```bash
docker run --rm --gpus all nvidia/cuda:12.1.0-base-ubuntu22.04 nvidia-smi
docker run --rm --runtime=nvidia -e NVIDIA_VISIBLE_DEVICES=all -e NVIDIA_DRIVER_CAPABILITIES=compute,utility nvidia/cuda:12.1.0-base-ubuntu22.04 nvidia-smi
```

两条都通过时，说明宿主机 GPU 容器通道正常。
