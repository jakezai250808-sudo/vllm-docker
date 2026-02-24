# 企业内网离线部署：Nginx + vLLM (Qwen3-Coder-Next)

本方案用于**无外网服务器**部署 OpenAI 兼容 API（`/v1/models`, `/v1/chat/completions`），并实现：
- Nginx 网关鉴权（API Key）+ IP 白名单
- vLLM 推理服务（模型写死为 `Qwen/Qwen3-Coder-Next`）
- Docker Compose 编排
- NVIDIA GPU 支持（`nvidia-container-toolkit`）
- 离线交付（`docker save/load`）

> ⚠️ 本版本将模型权重打包进 inference 镜像，镜像体积会非常大。

---

## 目录说明

- `docker-compose.yml`：编排网关与推理服务
- `nginx/nginx.conf` + `nginx/conf.d/api.conf`：白名单、鉴权、限流、超时、日志
- `vllm/Dockerfile`：构建离线 inference 镜像（内置模型）
- `vllm/entrypoint.sh`：按 env 启动 vLLM OpenAI Server
- `scripts/build_offline_bundle.sh`：办公电脑（可联网）下载模型 + 构建镜像 + 导出 tar
- `scripts/load_and_run.sh`：内网服务器加载 tar 并启动
- `.env.example`：参数样例

---

## 0) 前置要求

### 办公电脑（有外网）
- Docker
- Python3 + pip
- 可访问 Hugging Face（必要时使用代理）

### 内网服务器（无外网）
- Linux + Docker Engine + Docker Compose plugin
- NVIDIA 驱动与 `nvidia-container-toolkit`
  - 验证：`docker run --rm --gpus all nvidia/cuda:12.4.1-base-ubuntu22.04 nvidia-smi`

---

## 1) 办公电脑构建离线包

```bash
cd /path/to/repo
cp deploy/.env.example deploy/.env
bash deploy/scripts/build_offline_bundle.sh
```

如果需要代理（示例）：

```bash
export http_proxy=http://proxy.corp.local:3128
export https_proxy=http://proxy.corp.local:3128
bash deploy/scripts/build_offline_bundle.sh
```

脚本会完成：
1. 下载 `Qwen/Qwen3-Coder-Next` 到 `deploy/assets/models/Qwen3-Coder-Next`
2. 构建 `corp/qwen3-coder-next-vllm:offline`
3. 拉取并重标记 `corp/nginx-offline-gateway:1.27`
4. 导出 `deploy/dist/qwen3_coder_next_stack.tar`

---

## 2) 传输到内网服务器

通过 VPN/SCP/U 盘传输至少以下内容：
- `deploy/dist/qwen3_coder_next_stack.tar`
- `deploy/` 目录（至少 `docker-compose.yml`, `nginx/`, `.env`, `scripts/load_and_run.sh`）

---

## 3) 内网服务器加载并启动

```bash
cd /path/to/repo
cp deploy/.env.example deploy/.env
# 修改 API_KEY、ALLOWLIST、CUDA_VISIBLE_DEVICES、TP 等
bash deploy/scripts/load_and_run.sh
```

服务默认暴露：`http://<server-ip>:8080`

---

## 4) API 调用示例

### `/v1/models`

```bash
curl -sS http://127.0.0.1:8080/v1/models \
  -H 'Authorization: Bearer please-change-me' | jq .
```

### `/v1/chat/completions`

```bash
curl -sS http://127.0.0.1:8080/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -H 'Authorization: Bearer please-change-me' \
  -d '{
    "model": "Qwen3-Coder-Next",
    "messages": [
      {"role": "system", "content": "You are a helpful coding assistant."},
      {"role": "user", "content": "写一个 Python 快速排序"}
    ],
    "temperature": 0.2
  }'
```

---

## 5) 关键配置说明

- 白名单：`ALLOWLIST`（逗号分隔 CIDR）
  - 默认：`10/8, 172.16/12, 192.168/16, 100.64/10`
  - 如需新增 VPN 网段，直接改 `.env`。
- 鉴权：必须携带 `Authorization: Bearer <API_KEY>`，否则 401。
- 请求体限制：`MAX_BODY_SIZE`（默认 `50m`）
- 超时：Nginx 已设置 connect/read/send timeout（适配长生成）
- 限流：按 IP `limit_req`（`RATE_LIMIT_RPS`, `RATE_LIMIT_BURST`）
- GPU：
  - `gpus: all`
  - `CUDA_VISIBLE_DEVICES` 指定卡号
  - `TP` 控制 tensor parallel size（多卡时需 <= 可见 GPU 数）

---

## 6) 故障排查

### 401 Unauthorized
- 未携带 `Authorization` 头，或 token 与 `.env` 中 `API_KEY` 不一致。

### 403 Forbidden
- 客户端 IP 不在 `ALLOWLIST`。
- 若经过四层/七层代理，请确认源 IP 传递策略与白名单匹配。

### 502 Bad Gateway
- inference 尚未就绪或异常退出。
- 检查：
  ```bash
  docker compose -f deploy/docker-compose.yml --env-file deploy/.env ps
  docker compose -f deploy/docker-compose.yml --env-file deploy/.env logs -f inference
  ```
- 若显存不足，降低 `TP` 或 `MAX_MODEL_LEN`。

---

## 7) 运维建议

- 查看网关日志：
  ```bash
  docker compose -f deploy/docker-compose.yml --env-file deploy/.env logs -f gateway
  ```
- 滚动重启：
  ```bash
  docker compose -f deploy/docker-compose.yml --env-file deploy/.env up -d
  ```
- 停止：
  ```bash
  docker compose -f deploy/docker-compose.yml --env-file deploy/.env down
  ```

---

## 8) 模型升级说明

当前方案为“模型内置镜像”模式：
- 优点：离线部署简单、依赖少
- 缺点：镜像和 tar 体积大，换模型必须重新构建并重新分发 tar

未来可扩展“模型挂载版”（模型放宿主机卷，镜像不含权重）以减少镜像更新成本。
