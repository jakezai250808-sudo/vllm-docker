# A100 Edge Nginx Docker Image

本工程用于在 A100 宿主机上部署 Edge Nginx，反代同机仅监听回环地址的 vLLM 服务。

## 功能

- 监听宿主机 `0.0.0.0:${LISTEN_PORT}`（默认 `8000`）
- 反代 `/v1/*` 到 `http://127.0.0.1:${VLLM_LOCAL_PORT}/v1/*`（默认 `18000`）
- 使用白名单文件 `/etc/nginx/whitelist.conf` 进行访问控制（`allow ...;` + `deny all;`）
- 支持 streaming（SSE）
- 提供 `/healthz`
- 记录访问日志与错误日志

## 目录结构

```text
.
├── Dockerfile
├── docker-entrypoint.sh
├── nginx
│   └── nginx.conf.template
└── README.md
```

## whitelist.conf 示例

> 必须包含多行 `allow`，并以 `deny all;` 收尾。

```nginx
allow 52.9.8.7;
allow 52.9.8.8;
deny all;
```

## 构建镜像

默认使用本地已有 `nginx:stable` 镜像进行构建（不主动拉取远端）：

```bash
docker build --pull=never -t a100-edge-nginx:latest .
```

如本地不存在 `nginx:stable`，先拉取：

```bash
docker pull nginx:stable
```

## 运行容器（必须使用 host 网络）

```bash
docker run -d --name a100-edge-nginx --restart unless-stopped --network host \
  -e LISTEN_PORT=8000 -e VLLM_LOCAL_PORT=18000 \
  -v /opt/a100-edge/whitelist.conf:/etc/nginx/whitelist.conf:ro \
  a100-edge-nginx:latest
```

## 更新白名单后重载

```bash
docker exec a100-edge-nginx nginx -s reload
```

## 重要说明

- vLLM 必须监听 `127.0.0.1:18000`（或你设置的 `VLLM_LOCAL_PORT`）。
- Edge 容器必须使用 `--network host`，否则无法访问宿主机回环地址 `127.0.0.1` 上的 vLLM。
- 白名单在 `server` 级别生效，包含 `/healthz`、`/v1/` 在内的所有路径。

## 从办公区 Proxy / VPN 出口机器验证

```bash
curl http://<A100_IP>:8000/healthz
curl http://<A100_IP>:8000/v1/models
```

如果来源 IP 不在白名单中，将收到 `403 Forbidden`。
