#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/common.sh"

MODE="${MODE:-install}"
DRY_RUN="${DRY_RUN:-0}"
IDEA_CHANNEL="${IDEA_CHANNEL:-stable}"
CLION_CHANNEL="${CLION_CHANNEL:-stable}"
JAVA_PACKAGE="${JAVA_PACKAGE:-openjdk-21-jdk}"
INSTALL_INTELLIJ_IDEA="${INSTALL_INTELLIJ_IDEA:-1}"
INSTALL_CLION="${INSTALL_CLION:-1}"
ALLOW_SNAP_FAILURE="${ALLOW_SNAP_FAILURE:-1}"

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

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    error "Please run as root (sudo)."
    exit 1
  fi
}

detect_os() {
  if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    source /etc/os-release
    OS_ID="${ID:-unknown}"
    OS_PRETTY_NAME="${PRETTY_NAME:-unknown}"
  else
    OS_ID="unknown"
    OS_PRETTY_NAME="unknown"
  fi
}

ensure_snapd() {
  if command -v snap >/dev/null 2>&1; then
    return 0
  fi

  info "snap not found, installing snapd"
  run_cmd apt-get update
  run_cmd apt-get install -y snapd

  if command -v systemctl >/dev/null 2>&1; then
    run_cmd systemctl enable --now snapd
  fi
}

check_snap_store() {
  if [[ "${DRY_RUN}" == "1" ]]; then
    info "DRY_RUN=1, skip snap store connectivity check"
    return 0
  fi

  if snap info core >/dev/null 2>&1; then
    return 0
  fi

  if [[ "${ALLOW_SNAP_FAILURE}" == "1" ]]; then
    warn "Unable to connect to Snap Store; skip IDE installation via snap."
    warn "You can install JetBrains IDEs manually (offline package/toolbox) after network is available."
    return 1
  fi

  error "Unable to connect to Snap Store and ALLOW_SNAP_FAILURE=0"
  return 2
}

install_java() {
  info "Installing Java package: ${JAVA_PACKAGE}"
  run_cmd apt-get update
  run_cmd apt-get install -y "${JAVA_PACKAGE}"

  if [[ "${DRY_RUN}" != "1" ]]; then
    java -version || true
    javac -version || true
  fi
}

install_intellij_idea_ultimate() {
  if [[ "${INSTALL_INTELLIJ_IDEA}" != "1" ]]; then
    info "INSTALL_INTELLIJ_IDEA=${INSTALL_INTELLIJ_IDEA}, skip IntelliJ IDEA"
    return 0
  fi

  if ! check_snap_store; then
    return 0
  fi

  info "Installing IntelliJ IDEA Ultimate (${IDEA_CHANNEL}) via snap"
  run_cmd snap install intellij-idea-ultimate --classic --channel="${IDEA_CHANNEL}"
}

install_clion() {
  if [[ "${INSTALL_CLION}" != "1" ]]; then
    info "INSTALL_CLION=${INSTALL_CLION}, skip CLion"
    return 0
  fi

  if ! check_snap_store; then
    return 0
  fi

  info "Installing CLion (${CLION_CHANNEL}) via snap"
  run_cmd snap install clion --classic --channel="${CLION_CHANNEL}"
}

print_summary() {
  info "========== IDE setup summary =========="
  info "OS: ${OS_PRETTY_NAME}"
  if [[ "${DRY_RUN}" == "1" ]]; then
    info "DRY_RUN=1: commands previewed only"
  fi
  echo "Java package: ${JAVA_PACKAGE}"
  echo "IntelliJ IDEA: $([[ "${INSTALL_INTELLIJ_IDEA}" == "1" ]] && echo enabled || echo disabled)"
  echo "CLion: $([[ "${INSTALL_CLION}" == "1" ]] && echo enabled || echo disabled)"
  echo "ALLOW_SNAP_FAILURE: ${ALLOW_SNAP_FAILURE}"
}

parse_args "$@"
detect_os

if [[ "${OS_ID}" != "ubuntu" ]]; then
  warn "This script is designed for Ubuntu. Detected: ${OS_PRETTY_NAME}"
fi

if [[ "${MODE}" == "check" ]]; then
  print_summary
  exit 0
fi

require_root
export DEBIAN_FRONTEND=noninteractive

install_java
ensure_snapd
install_intellij_idea_ultimate
install_clion
print_summary
