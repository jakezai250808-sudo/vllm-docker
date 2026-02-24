#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/common.sh"

require_cmd tar

DIST_DIR="${DEPLOY_DIR}/dist"
RELEASE_NAME="${RELEASE_NAME:-llm_offline_release}"
RELEASE_BUNDLE_GLOB="${RELEASE_BUNDLE_GLOB:-qwen3_coder_next_stack.tar*}"
RELEASE_TMP_DIR="$(mktemp -d -t llm_offline_release_XXXXXX)"
RELEASE_ROOT_DIR="${RELEASE_TMP_DIR}/${RELEASE_NAME}"
RELEASE_ARCHIVE="${DIST_DIR}/${RELEASE_NAME}.tar.gz"

cleanup() {
  rm -rf "${RELEASE_TMP_DIR}"
}
trap cleanup EXIT

shopt -s nullglob
bundle_files=("${DIST_DIR}"/*.tar "${DIST_DIR}"/*.tar.zst)
if [[ ${#bundle_files[@]} -eq 0 ]]; then
  echo "No image bundle found in ${DIST_DIR}. Run build_offline_bundle.sh first." >&2
  exit 1
fi

mkdir -p "${RELEASE_ROOT_DIR}"

log "Preparing portable release structure"
mkdir -p "${RELEASE_ROOT_DIR}/deploy"
(
  cd "${DEPLOY_DIR}"
  tar \
    --exclude='dist/.release_tmp' \
    --exclude='dist/tmp' \
    --exclude='dist/*.tar' \
    --exclude='dist/*.tar.zst' \
    --exclude='dist/*.tar.gz' \
    -cf - .
) | (
  cd "${RELEASE_ROOT_DIR}/deploy"
  tar -xf -
)

mkdir -p "${RELEASE_ROOT_DIR}/deploy/dist"
selected_bundle_files=("${DIST_DIR}"/${RELEASE_BUNDLE_GLOB})
if [[ ${#selected_bundle_files[@]} -eq 0 ]]; then
  log "No files matched RELEASE_BUNDLE_GLOB=${RELEASE_BUNDLE_GLOB}, fallback to all *.tar/*.tar.zst"
  selected_bundle_files=("${DIST_DIR}"/*.tar "${DIST_DIR}"/*.tar.zst)
fi
cp -a "${selected_bundle_files[@]}" "${RELEASE_ROOT_DIR}/deploy/dist/"

cat > "${RELEASE_ROOT_DIR}/run_on_server.sh" <<'RUNNER'
#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${BASE_DIR}/deploy"

if [[ ! -f .env ]]; then
  cp .env.example .env
  echo "[INFO] .env not found; generated from .env.example. Please edit API_KEY in deploy/.env, then rerun." >&2
  exit 1
fi

chmod +x scripts/*.sh || true
bash scripts/load_and_run.sh
RUNNER
chmod +x "${RELEASE_ROOT_DIR}/run_on_server.sh"

log "Creating portable archive ${RELEASE_ARCHIVE}"
tar -C "${RELEASE_TMP_DIR}" -czf "${RELEASE_ARCHIVE}" "${RELEASE_NAME}"

log "Portable release ready: ${RELEASE_ARCHIVE}"
log "Server usage: tar -xzf ${RELEASE_ARCHIVE} && cd ${RELEASE_NAME} && ./run_on_server.sh"
