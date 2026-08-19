#!/usr/bin/env bash

set -Eeuo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly COMMON_CONFIG="${SCRIPT_DIR}/../config/common-config.sh"
readonly COMMON_FUNCTIONS="${SCRIPT_DIR}/../config/common-functions.sh"
# shellcheck source=../config/common-config.sh
source "${COMMON_CONFIG}"
# shellcheck source=../config/common-functions.sh
source "${COMMON_FUNCTIONS}"
readonly PACKAGE_DIR="$SCRIPT_DIR/artifacts/packages"
readonly TOOLS_VERSION="100.17.0"
readonly DEB="$PACKAGE_DIR/mongodb-database-tools-ubuntu2404-x86_64-$TOOLS_VERSION.deb"
readonly RPM="$PACKAGE_DIR/mongodb-database-tools-rhel93-x86_64-$TOOLS_VERSION.rpm"
readonly DEB_SHA="cfc40386b5c909509fd4b35a4a1f212aeaedc17a3062703d4b4b0823c2beb1b7"
readonly RPM_SHA="d3c341c123e29d376b36d7245c9eed5ec0ea283d839cedb6017348c27269e78f"

VERIFY_ONLY=false
TARGET=""

usage() {
  cat <<'USAGE'
Install bundled MongoDB Database Tools for mongo-backup-v2

Usage:
  sudo ./install-prerequisites.sh
  ./install-prerequisites.sh --verify-only

Options:
      --verify-only   Verify both bundled packages without changing the host
  -h, --help          Show this help

Installation targets:
  Ubuntu 24.04 x86-64   mongodb-database-tools Ubuntu 24.04 .deb
  Rocky Linux 9 x86-64 RHEL 9 .rpm

kubectl is required but is not installed by this script.
USAGE
}

fail() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }
info() { printf '[INFO] %s\n' "$*"; }

verify_file() {
  [[ -f "$1" ]] || fail "missing package: $1"
  [[ "$(sha256_file "$1")" == "$2" ]] || fail "checksum mismatch: ${1##*/}"
  info "Verified ${1##*/}"
}

verify_bundle() {
  verify_file "$DEB" "$DEB_SHA"
  verify_file "$RPM" "$RPM_SHA"
}

detect_target() {
  local os_id os_version
  [[ "$(uname -s)" == "Linux" && "$(uname -m)" == "x86_64" ]] \
    || fail "bundled packages require Linux x86-64"
  [[ -r /etc/os-release ]] || fail "cannot identify this Linux distribution"
  os_id=$(. /etc/os-release; printf '%s' "${ID:-}")
  os_version=$(. /etc/os-release; printf '%s' "${VERSION_ID:-}")
  case "$os_id:$os_version" in
    ubuntu:24.04) TARGET=ubuntu ;;
    rocky:9.*) TARGET=rocky ;;
    *) fail "supported targets are Ubuntu 24.04 or Rocky Linux 9 x86-64" ;;
  esac
}

install_tools() {
  case "$TARGET" in
    ubuntu)
      info "Installing Ubuntu prerequisites and bundled Database Tools $TOOLS_VERSION"
      as_root apt-get update
      as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y \
        --no-install-recommends bash ca-certificates coreutils findutils grep \
        mawk python3 sed "$DEB"
      ;;
    rocky)
      info "Installing Rocky Linux prerequisites and bundled Database Tools $TOOLS_VERSION"
      as_root dnf makecache
      as_root dnf install -y bash ca-certificates coreutils findutils gawk grep \
        python3 sed "$RPM"
      ;;
  esac
  command -v mongodump >/dev/null 2>&1 || fail "mongodump was not installed"
  mongodump --version | sed -n '1p'
}

main() {
  while (($#)); do
    case "$1" in
      --verify-only) VERIFY_ONLY=true; shift ;;
      -h|--help) usage; exit 0 ;;
      *) fail "unknown option: $1" ;;
    esac
  done
  verify_bundle
  [[ "$VERIFY_ONLY" == "false" ]] || { info "No host changes were made"; exit 0; }
  detect_target
  install_tools
  info "Prerequisites installed; rerun ./palette-ec-backup.sh --check-prerequisites"
}

main "$@"
