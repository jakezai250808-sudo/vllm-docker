# LLM Gateway Proxy (Nginx)

一个可构建的 Nginx Docker 镜像工程，用于办公区访问服务器区 vLLM API 的代理网关。

## 功能概览

- 办公网用户访问：`http://<PROXY_IP>:80/v1/*`
- 代理上游：`http://<A100_EDGE_HOST>:8000/v1/*`（可通过环境变量调整端口）
- IP 白名单（通过文件挂载实现）
- `/v1/` API Key 鉴权（`Authorization: Bearer <KEY>`）
- 支持 vLLM streaming（SSE）
- 基本限流
- 访问日志与错误日志
- 健康检查：`/healthz`

## 目录结构

```text
.
├── Dockerfile
├── docker-entrypoint.sh
├── nginx/
│   └── nginx.conf.template
└── README.md
```

## 配置说明

### 必填环境变量

- `UPSTREAM_HOST`：上游服务地址（例如 `52.1.2.3`）
- `API_KEY`：鉴权令牌值（不含 `Bearer ` 前缀）

### 可选环境变量

- `UPSTREAM_PORT`：上游端口，默认 `8000`
- `RATE_LIMIT_RPS`：限流速率（每秒请求数），默认 `5`
- `RATE_LIMIT_BURST`：突发请求数，默认 `20`
- `SERVER_PORT`：Nginx 监听端口，默认 `80`

### 白名单文件（必须挂载）

容器固定读取：`/etc/nginx/whitelist.conf`

示例内容（多行 `allow`，最后一行 `deny all;`）：

```nginx
allow 10.10.10.21;
allow 10.10.10.35;
deny all;
```

> 若文件不存在，或不包含 `deny all;`，容器会启动失败并给出错误提示。

## 构建镜像

```bash
docker build -t llm-gw:latest .
```

## 运行容器（强调挂载 whitelist.conf）

```bash
docker run -d --name llm-gw -p 80:80 \
  -e UPSTREAM_HOST=52.1.2.3 -e API_KEY=your-secret-key \
  -v /opt/llm-gw/whitelist.conf:/etc/nginx/whitelist.conf:ro \
  llm-gw:latest
```

## 修改白名单后重载

```bash
docker exec llm-gw nginx -s reload
```

## curl 示例

```bash
curl http://<PROXY_IP>/healthz -H "Authorization: Bearer your-secret-key"
curl http://<PROXY_IP>/v1/models -H "Authorization: Bearer your-secret-key"
```

## 行为说明

- 白名单规则在 `server` 级别生效，任何路径（包括 `/healthz`）都受 IP 访问控制。
- `/v1/` 强制校验 `Authorization` 头，必须严格等于 `Bearer ${API_KEY}`，否则返回 `401`。
- `/v1/` 代理关闭缓冲并设置长超时，适配 vLLM streaming（SSE）。
- 其他路径返回 `404`。
