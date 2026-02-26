#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/common.sh"

MODE="${MODE:-check}"
NVIDIA_DRIVER_PACKAGE="${NVIDIA_DRIVER_PACKAGE:-nvidia-driver-550}"
INSTALL_NVIDIA_TOOLKIT="${INSTALL_NVIDIA_TOOLKIT:-1}"
INSTALL_NVIDIA_DRIVER="${INSTALL_NVIDIA_DRIVER:-0}"
SKIP_REBOOT_HINT="${SKIP_REBOOT_HINT:-0}"
DRY_RUN="${DRY_RUN:-0}"

info() {
  log "[INFO] $*"
}

warn() {
  log "[WARN] $*" >&2
}

error() {
  log "[ERROR] $*" >&2
}

run_cmd() {
  if [[ "${DRY_RUN}" == "1" ]]; then
    echo "[DRY-RUN] $*"
    return 0
  fi
  "$@"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run)
        DRY_RUN=1
        shift
        ;;
      --mode)
        MODE="$2"
        shift 2
        ;;
      *)
        error "Unknown argument: $1"
        exit 1
        ;;
    esac
  done
}

require_root_if_install() {
  if [[ "${MODE}" != "check" ]] && [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    error "MODE=${MODE} requires root. Please re-run with sudo."
    exit 1
  fi
}

detect_os() {
  if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    source /etc/os-release
    OS_ID="${ID:-unknown}"
    OS_VERSION_ID="${VERSION_ID:-unknown}"
    OS_PRETTY_NAME="${PRETTY_NAME:-unknown}"
  else
    OS_ID="unknown"
    OS_VERSION_ID="unknown"
    OS_PRETTY_NAME="unknown"
  fi
}

print_hardware_report() {
  info "========== Host Hardware/Driver Report =========="
  info "OS: ${OS_PRETTY_NAME}"

  if command -v lspci >/dev/null 2>&1; then
    info "PCI NVIDIA devices:"
    lspci | grep -Ei 'nvidia|vga|3d' || warn "No NVIDIA/VGA/3D devices found via lspci"
  else
    warn "lspci not found (install pciutils for richer detection output)"
  fi

  if command -v nvidia-smi >/dev/null 2>&1; then
    info "nvidia-smi summary:"
    nvidia-smi || warn "nvidia-smi exists but command failed"
  else
    warn "nvidia-smi not found"
  fi

  if command -v docker >/dev/null 2>&1; then
    info "Docker version: $(docker --version 2>/dev/null || echo unavailable)"
    if docker info --format '{{json .Runtimes}}' 2>/dev/null | grep -q 'nvidia'; then
      info "Docker NVIDIA runtime detected"
    else
      warn "Docker NVIDIA runtime not detected"
    fi
  else
    warn "docker not found"
  fi
}

apt_install_basics() {
  export DEBIAN_FRONTEND=noninteractive
  run_cmd apt-get update
  run_cmd apt-get install -y --no-install-recommends \
    curl \
    ca-certificates \
    gnupg \
    lsb-release \
    pciutils
}

install_nvidia_driver() {
  if [[ "${INSTALL_NVIDIA_DRIVER}" != "1" ]]; then
    info "INSTALL_NVIDIA_DRIVER=${INSTALL_NVIDIA_DRIVER}, skip driver installation"
    return 0
  fi

  if [[ "${OS_ID}" != "ubuntu" ]]; then
    warn "Automatic driver installation currently supports Ubuntu only. Skipped."
    return 0
  fi

  info "Installing NVIDIA driver package: ${NVIDIA_DRIVER_PACKAGE}"
  run_cmd apt-get install -y "${NVIDIA_DRIVER_PACKAGE}"
}

install_nvidia_container_toolkit() {
  if [[ "${INSTALL_NVIDIA_TOOLKIT}" != "1" ]]; then
    info "INSTALL_NVIDIA_TOOLKIT=${INSTALL_NVIDIA_TOOLKIT}, skip toolkit installation"
    return 0
  fi

  if [[ "${OS_ID}" != "ubuntu" ]]; then
    warn "Automatic nvidia-container-toolkit installation currently supports Ubuntu only. Skipped."
    return 0
  fi

  info "Installing nvidia-container-toolkit"
  local keyring_path="/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg"
  local list_path="/etc/apt/sources.list.d/nvidia-container-toolkit.list"

  if [[ "${DRY_RUN}" == "1" ]]; then
    echo "[DRY-RUN] curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | gpg --dearmor -o ${keyring_path}"
  else
    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
      | gpg --dearmor -o "${keyring_path}"
  fi

  if [[ "${DRY_RUN}" == "1" ]]; then
    echo "[DRY-RUN] write ${list_path} from NVIDIA toolkit list"
  else
    curl -fsSL "https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list" \
      | sed "s#deb https://#deb [signed-by=${keyring_path}] https://#g" \
      > "${list_path}"
  fi

  run_cmd apt-get update
  run_cmd apt-get install -y nvidia-container-toolkit

  if command -v nvidia-ctk >/dev/null 2>&1; then
    run_cmd nvidia-ctk runtime configure --runtime=docker
  else
    warn "nvidia-ctk command not found after install"
  fi

  if command -v systemctl >/dev/null 2>&1; then
    run_cmd systemctl restart docker || warn "Failed to restart docker via systemctl"
  else
    warn "systemctl not available; please restart docker service manually"
  fi
}

print_next_steps() {
  info "========== Next Steps =========="
  echo "1) Verify driver: nvidia-smi"
  echo "2) Verify Docker GPU runtime: docker run --rm --gpus all nvidia/cuda:12.1.0-base-ubuntu22.04 nvidia-smi"
  echo "3) If changing kernel driver, reboot host before production rollout"

  if [[ "${SKIP_REBOOT_HINT}" != "1" ]]; then
    warn "If this script installed/updated NVIDIA driver, reboot is usually required."
  fi
}

run_install_flow() {
  require_root_if_install
  detect_os

  if [[ "${MODE}" == "check" ]]; then
    print_hardware_report
    print_next_steps
    return 0
  fi

  apt_install_basics
  install_nvidia_driver
  install_nvidia_container_toolkit

  print_hardware_report
  print_next_steps
}

parse_args "$@"

case "${MODE}" in
  check|install)
    run_install_flow
    ;;
  *)
    error "Unsupported MODE=${MODE}. Use MODE=check or MODE=install"
    exit 1
    ;;
esac
