#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
DEPLOY_DIR=$(cd "${SCRIPT_DIR}/.." && pwd)
REPO_ROOT=$(cd "${DEPLOY_DIR}/.." && pwd)

MODEL_ID="Qwen/Qwen3-Coder-Next"
MODEL_DIR="${DEPLOY_DIR}/assets/models/Qwen3-Coder-Next"
DIST_DIR="${DEPLOY_DIR}/dist"
TAR_PATH="${DIST_DIR}/qwen3_coder_next_stack.tar"

INFERENCE_IMAGE="corp/qwen3-coder-next-vllm:offline"
GATEWAY_IMAGE="corp/nginx-offline-gateway:1.27"

mkdir -p "${MODEL_DIR}" "${DIST_DIR}"

echo "[1/4] 检查依赖 (docker, huggingface-cli)..."
command -v docker >/dev/null
if ! command -v huggingface-cli >/dev/null 2>&1; then
  echo "[INFO] 未检测到 huggingface-cli，尝试安装..."
  python3 -m pip install --user -U "huggingface_hub[cli]"
  export PATH="$HOME/.local/bin:$PATH"
fi

echo "[2/4] 下载模型 ${MODEL_ID} -> ${MODEL_DIR}"
echo "[提示] 如需代理可先导出: export http_proxy=http://proxy:port https_proxy=http://proxy:port"
huggingface-cli download "${MODEL_ID}" --local-dir "${MODEL_DIR}" --local-dir-use-symlinks False

echo "[3/4] 构建 inference 镜像 ${INFERENCE_IMAGE}"
cd "${REPO_ROOT}"
docker build -f deploy/vllm/Dockerfile -t "${INFERENCE_IMAGE}" .

echo "[3.5/4] 准备 gateway 镜像 ${GATEWAY_IMAGE}"
docker pull nginx:1.27-alpine
docker tag nginx:1.27-alpine "${GATEWAY_IMAGE}"

echo "[4/4] 导出离线镜像包 ${TAR_PATH}"
docker save -o "${TAR_PATH}" "${INFERENCE_IMAGE}" "${GATEWAY_IMAGE}"

cat <<MSG

完成：
- 模型目录：${MODEL_DIR}
- 离线镜像包：${TAR_PATH}

请将以下内容复制到内网服务器：
1) deploy/dist/qwen3_coder_next_stack.tar
2) deploy/ 整个目录（至少 docker-compose.yml、nginx/、.env）
MSG
