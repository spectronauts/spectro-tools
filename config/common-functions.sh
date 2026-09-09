#!/bin/bash
#######################################################################################
# Script Name: common-functions.sh
# Description: Shared helpers for the utilities in this repository.
# Author: Jason Cuff
#######################################################################################

if [[ "${SPECTRO_COMMON_FUNCTIONS_LOADED:-false}" == "true" ]]; then
  return 0
fi
SPECTRO_COMMON_FUNCTIONS_LOADED=true

timestamp() {
  date "+%Y-%m-%d %H:%M:%S"
}

techo() {
  echo "$(timestamp): $*"
}

is-kubeconfig-set() {
  [[ -n "${KUBECONFIG:-}" ]]
}

can-i-list() {
  local resource="$1"
  local namespace="${2:-}"
  if [[ -n "${namespace}" ]]; then
    [[ "$(kubectl auth can-i list "${resource}" -n "${namespace}" 2>/dev/null)" == "yes" ]]
  else
    [[ "$(kubectl auth can-i list "${resource}" 2>/dev/null)" == "yes" ]]
  fi
}

can-list-pods-in-namespace() {
  can-i-list pods "$1"
}

require_value() {
  local option="${1:-option}"
  local value="${2:-}"
  local message="${option} requires a value"
  [[ -n "${value}" && "${value}" != --* ]] && return 0

  if declare -F usage_error >/dev/null 2>&1; then
    usage_error "${message}"
  elif declare -F log_error >/dev/null 2>&1; then
    log_error "${message}"
    return 2
  else
    printf 'ERROR: %s\n' "${message}" >&2
    return 2
  fi
}

validate_port() {
  local name="${1:-port}"
  local value="${2:-}"
  local message="Invalid ${name}: ${value} (expected 1-65535)"
  if [[ "${value}" =~ ^[0-9]+$ ]] &&
    ((10#${value} >= 1 && 10#${value} <= 65535)); then
    return 0
  fi

  if declare -F usage_error >/dev/null 2>&1; then
    usage_error "${message}"
  elif declare -F log_error >/dev/null 2>&1; then
    log_error "${message}"
    return 2
  else
    printf 'ERROR: %s\n' "${message}" >&2
    return 2
  fi
}

sha256_file() {
  local output
  if command -v sha256sum >/dev/null 2>&1; then
    output=$(sha256sum "$1")
  elif command -v shasum >/dev/null 2>&1; then
    output=$(shasum -a 256 "$1")
  else
    if declare -F fail >/dev/null 2>&1; then
      fail "sha256sum or shasum is required"
    else
      printf 'ERROR: sha256sum or shasum is required\n' >&2
    fi
    return 1
  fi
  printf '%s\n' "${output%% *}"
}

decode_base64() {
  if base64 --help 2>&1 | grep -q -- '--decode'; then
    base64 --decode
  else
    base64 -D
  fi
}

kubectl_cmd() {
  kubectl --kubeconfig "${KUBECONFIG_FILE}" "$@"
}

select_local_port() {
  python3 -c 'import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()'
}

require_command() {
  command -v "$1" >/dev/null 2>&1 && return 0
  if declare -F log_error >/dev/null 2>&1; then
    log_error "Required command not found: $1"
  elif declare -F fail >/dev/null 2>&1; then
    fail "Required command not found: $1"
  else
    printf 'ERROR: Required command not found: %s\n' "$1" >&2
  fi
  return 1
}

confirm_action() {
  local prompt="$1"
  local answer=""
  [[ -t 0 ]] || return 1
  printf '%s [y/N]: ' "${prompt}"
  IFS= read -r answer || answer=""
  case "${answer}" in
    y|Y|yes|YES|Yes) return 0 ;;
    *) return 1 ;;
  esac
}

# Palette and the extracted air-gap tooling append the spectro-packs repository
# namespace. Return only the configured parent path so it is not duplicated.
resolve_ecr_pack_base() {
  local base_content_path="${1:-}"
  local pack_base="${2:-}"
  local resolved_base

  base_content_path="${base_content_path#/}"
  base_content_path="${base_content_path%/}"
  pack_base="${pack_base#/}"
  pack_base="${pack_base%/}"
  resolved_base="${base_content_path}${base_content_path:+${pack_base:+/}}${pack_base}"

  if [[ "${resolved_base}" == "spectro-packs" ]]; then
    resolved_base=""
  elif [[ "${resolved_base}" == */spectro-packs ]]; then
    resolved_base="${resolved_base%/spectro-packs}"
  fi

  printf '%s\n' "${resolved_base}"
}

build_palette_pack_registry() {
  local registry="${1:-}"
  local base_path

  registry="${registry%/}"
  base_path="$(resolve_ecr_pack_base "${2:-}" "${3:-}")"
  printf '%s%s\n' "${registry}" "${base_path:+/${base_path}}"
}

as_root() {
  if ((EUID == 0)); then
    "$@"
  else
    if ! command -v sudo >/dev/null 2>&1; then
      if declare -F fail >/dev/null 2>&1; then
        fail "run as root or install sudo"
      else
        printf 'ERROR: run as root or install sudo\n' >&2
      fi
      return 1
    fi
    sudo "$@"
  fi
}

load_config_values() {
  local overwrite=false
  if [[ "${1:-}" == "--overwrite" ]]; then
    overwrite=true
    shift
  fi

  local config_file="${1:-}"
  local allowed=false
  local candidate key value
  [[ -n "${config_file}" ]] || {
    printf 'ERROR: load_config_values requires a config file\n' >&2
    return 1
  }
  shift
  [[ -f "${config_file}" ]] || {
    printf 'ERROR: config file not found: %s\n' "${config_file}" >&2
    return 1
  }

  while IFS='=' read -r key value || [[ -n "${key}" ]]; do
    key="${key#"${key%%[![:space:]]*}"}"
    key="${key%"${key##*[![:space:]]}"}"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    [[ -z "${key}" || "${key}" == \#* ]] && continue
    case "${value}" in
      \"*\") value="${value:1:${#value}-2}" ;;
      \'*\') value="${value:1:${#value}-2}" ;;
    esac

    allowed=false
    for candidate in "$@"; do
      if [[ "${candidate}" == "${key}" ]]; then
        allowed=true
        break
      fi
    done
    if [[ "${allowed}" == "true" ]]; then
      if [[ "${overwrite}" == "true" || -z "${!key:-}" ]]; then
        printf -v "${key}" '%s' "${value}"
      fi
    else
      printf 'Warning: ignoring unknown config key: %s\n' "${key}" >&2
    fi
  done < "${config_file}"
}

validateVar() {
  # Usage:
  #   validateVar <variablename>             # exits on missing var
  #   validateVar <variablename> fatal       # exits on missing var
  #   validateVar <variablename> warn        # continues on missing var
  #   validateVar <variablename> warn mask   # validates but redacts the value

  local var_name="${1:-}"
  local mode="${2:-fatal}"
  local display_mode="${3:-plain}"
  local value="${!var_name:-}"

  case "${var_name}" in
    DOWNLOAD_USER|DOWNLOAD_PASS)
      display_mode="mask"
      ;;
  esac

  if [[ -z "$var_name" ]]; then
    echo "❌ Error: validateVar requires a variable name" >&2
    [[ "$mode" == "fatal" ]] && exit 1
    return 1
  fi

  if [[ -z "$value" ]]; then
    if [[ "$mode" == "fatal" ]]; then
      echo "❌ Error: variable '$var_name' is not set or is empty" >&2
      exit 1
    else
      echo "⚠️  Warning: variable '$var_name' is not set or is empty" >&2
      return 1
    fi
  else
    if [[ "$display_mode" == "mask" ]]; then
      echo "✅ $var_name: [REDACTED]"
    else
      echo "✅ $var_name: $value"
    fi
    return 0
  fi
}
# function validateVar () { #Usage: validateVar <variablename>
#   local var_name="$1"
#   local value="${!var_name}"
#   if [[ -z "$value" ]]; then
#     echo "❌ Error: variable '$var_name' is not set or is empty" >&2
#     exit 1
#   else
#     echo "✅ $var_name: $value"
#   fi
# }

function print_boxed () { #Usage: print_boxed <message>
  local message="$1"
  local len=${#message}
  local border
  border=$(printf '%*s' $((len + 4)) '' | tr ' ' '#')
  echo -e "\n$border"
  echo -e "# $message #"
  echo -e "$border\n"
}

function warn() {
  local msg="$*"
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARN: ${msg}"
}

function fail() {
  local msg="$*"
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: ${msg}"
  exit 1
}

function extract_binary() {
  local binary="$1"
  local airgap_dir="$2"

  if [[ -d "${airgap_dir}" ]]; then
    fail "Extraction target already exists: ${airgap_dir}. Use --skip-extraction to reuse it, or remove it first."
  fi

  make_executable_if_needed "${binary}"

  echo "Extracting ${binary} to ${airgap_dir}"

  "${binary}" --noexec --target "${airgap_dir}"

  if [[ ! -d "${airgap_dir}" ]]; then
    fail "Extraction completed but expected directory was not created: ${airgap_dir}"
  fi

  echo "Extraction completed: ${airgap_dir}"
}

function make_executable_if_needed() {
  local file="$1"

  if [[ ! -f "${file}" ]]; then
    fail "Expected file not found: ${file}"
  fi

  if [[ ! -x "${file}" ]]; then
    echo "File is not executable. Running chmod +x: ${file}"
    chmod +x "${file}" || fail "Failed to chmod +x ${file}"
  fi
}

function patch_push_destination_output() {
  local functions_file="$1"
  local temporary_file
  temporary_file="$(mktemp "${functions_file}.push-paths.XXXXXX")"

  if ! awk '
    function indentation(line, whitespace) {
      whitespace = line
      sub(/[^ \t].*$/, "", whitespace)
      return whitespace
    }

    /^apply_ecr_images\(\)/ {
      scope = "images"
    }
    /^ecr_pack_push\(\)/ {
      scope = "packs"
    }

    scope == "images" &&
      index($0, "status_display \" - Pushing image $image_url\"") {
        prefix = indentation($0)
        print prefix "status_display \" - Pushing image to ${image_dst_url}/${image_url}\""
        print prefix "status_display \" - Pushing image to ${image_dst_url}/${image_url2}\""
        next
      }

    scope == "packs" &&
      index($0, "status_display \" - Pushing Pack $NAME:$VERSION\"") {
        prefix = indentation($0)
        if ((getline following_line) > 0) {
          if (index(following_line, "status_display \" - Pushing Scar OCI $NAME:$VERSION\"")) {
            print prefix "status_display \" - Pushing Scar OCI to ${pack_registry}/${scar_oci_loc}/$NAME:$VERSION\""
            next
          }
          print prefix "status_display \" - Pushing Pack to ${pack_registry}/${pack_loc}/$NAME:$VERSION\""
          print following_line
          next
        }
        print prefix "status_display \" - Pushing Pack to ${pack_registry}/${pack_loc}/$NAME:$VERSION\""
        next
      }

    scope == "packs" &&
      index($0, "status_display \" - Pushing Scar OCI $NAME:$VERSION\"") {
        prefix = indentation($0)
        print prefix "status_display \" - Pushing Scar OCI to ${pack_registry}/${scar_oci_loc}/$NAME:$VERSION\""
        next
      }

    {
      print
      if ($0 == "}") {
        scope = ""
      }
    }
  ' "${functions_file}" >"${temporary_file}"; then
    rm -f "${temporary_file}"
    fail "Failed to add resolved push destinations to ${functions_file}"
  fi

  if ! cat "${temporary_file}" >"${functions_file}"; then
    rm -f "${temporary_file}"
    fail "Failed to update ${functions_file} with resolved push destinations"
  fi
  rm -f "${temporary_file}"
}

function patch_functions_file() {
  local airgap_dir="$1"
  local os_type="$2"
  local functions_file="${airgap_dir}/bin/functions.sh"

  if [[ ! -f "${functions_file}" ]]; then
    warn "functions.sh not found at ${functions_file}; skipping airgap function patches."
    return
  fi

  if [[ ! -w "${functions_file}" ]]; then
    fail "functions.sh exists but is not writable: ${functions_file}"
  fi

  echo "Patching ${functions_file}: replacing ecr-public with ecr"
  case "${os_type}" in
    macos)
      sed -i '' "s/ecr-public/ecr/g" "${functions_file}"
      ;;
    linux|wsl|windows)
      sed -i "s/ecr-public/ecr/g" "${functions_file}"
      ;;
    *)
      fail "Unsupported operating system for patching ${functions_file}: ${os_type}"
      ;;
  esac

  echo "Patching ${functions_file}: displaying exact image and pack destinations"
  patch_push_destination_output "${functions_file}"
}

function create_ecr_repo() {
  local repo_name="$1"

  repo_name="${repo_name#/}"
  repo_name="${repo_name%/}"

  echo "  Creating: ${repo_name}"

  if aws ecr describe-repositories \
    --repository-names "${repo_name}" \
    --region "${AWS_REGION}" >/dev/null 2>&1; then
    echo "    ↩ Already exists"
    return 0
  fi

  if ! aws ecr create-repository \
    --repository-name "${repo_name}" \
    --region "${AWS_REGION}" >/dev/null; then
    echo "    ✗ Failed to create repository: ${repo_name}" >&2
    return 1
  fi

  echo "    ✓ Created"
}

function extract_missing_repos() {
  local output="$1"

  {
    # Matches missing pack repos like:
    # spectro-packs/archive/generic-byoi does not exist
    printf '%s\n' "$output" |
      sed -nE "s#.*archive/([^'\"[:space:]]+) does not exist.*#${ECR_PACK_BASE%/}/archive/\1#p"

    # Matches missing image repos like:
    # spectro-images/some-image does not exist
    printf '%s\n' "$output" |
      sed -nE "s#.*spectro-images/([^'\"[:space:]]+) does not exist.*#${ECR_IMAGE_BASE%/}/\1#p"
  } | sed -E 's#@sha256:[a-fA-F0-9]+$##; s#:[^/]+$##' | sort -u
}

function run_apply_script_with_repo_retry() {
  local script_path="$1"
  local script_name
  script_name="$(basename "${script_path}")"

  if [[ ! -f "${script_path}" ]]; then
    warn "${script_name} not found. Skipping."
    return
  fi

  make_executable_if_needed "${script_path}"

  local attempt=1
  local max_attempts=20

  while true; do
    echo "Running ${script_name}, attempt ${attempt}/${max_attempts}"

    local attempt_log
    attempt_log="$(mktemp "/tmp/${script_name}.attempt.${attempt}.XXXXXX.log")"

    set +e

    # Stream output live to screen and LOG_FILE, while also saving this attempt's output.
    "./${script_name}" 2>&1 | tee "${attempt_log}"

    local rc=${PIPESTATUS[0]}
    set -e

    if [[ ${rc} -eq 0 ]]; then
      echo "${script_name} completed successfully."
      rm -f "${attempt_log}"
      break
    fi

    warn "${script_name} exited with code ${rc}"

    local output
    output="$(cat "${attempt_log}")"

    if create_missing_pack_repos "${output}"; then
      rm -f "${attempt_log}"

      if [[ ${attempt} -ge ${max_attempts} ]]; then
        fail "${script_name} still failing after ${max_attempts} attempts."
      fi

      echo "Missing repos were created. Retrying ${script_name}."
      attempt=$((attempt + 1))
      continue
    fi

    cat "${attempt_log}"
    rm -f "${attempt_log}"

    fail "${script_name} failed and no missing repo pattern was detected."
  done
}

function create_missing_pack_repos() {
  local output="$1"
  local missing
  missing="$(
    printf '%s\n' "${output}" |
      sed -nE "s#.*archive/([^'\"[:space:]]+) does not exist.*#\1#p" |
      sort -u
  )"

  if [[ -z "${missing}" ]]; then
    return 1
  fi

  echo "Detected missing ECR pack archive repositories:"
  printf '%s\n' "${missing}"

  local pack_repo_base="${ECR_PACK_BASE%/}"
  if [[ "${pack_repo_base##*/}" != "spectro-packs" ]]; then
    pack_repo_base="${pack_repo_base:+${pack_repo_base}/}spectro-packs"
  fi

  while IFS= read -r pack; do
    [[ -z "${pack}" ]] && continue

    local repo
    repo="${pack_repo_base}/archive/${pack}"
    create_ecr_repo "${repo}" ||
      fail "Failed to create missing ECR repository: ${repo}"
  done <<< "${missing}"

  return 0
}

function download_file() { #1=version
  local version="$1"

  if [[ -z "$version" ]]; then
    echo "Usage: download_file <version>"
    return 1
  fi

  local username="spectro"
  local password=""
  local base_url="https://software-private.spectrocloud.com/airgap-vertex"
  local filename="airgap-vertex-v${version}.bin"
  local url="${base_url}/${version}/${filename}"
  local download_dir="${SCRIPT_DIR:-.}/downloads"

  mkdir -p "${download_dir}"

  curl -fL \
    --user "${username}:${password}" \
    --connect-timeout 10 \
    --retry 3 \
    --retry-delay 5 \
    -o "${download_dir}/${filename}" \
    "${url}"
}

function ecrLogin() {
  # Usage: ecrLogin
  # Requires: AWS_REGION, ECR_REGISTRY

  validateVar AWS_REGION
  validateVar ECR_REGISTRY

  echo "Logging into ECR with oras: ${ECR_REGISTRY}"

  if ! aws ecr get-login-password --region "${AWS_REGION}" |
    oras login --username AWS --password-stdin "${ECR_REGISTRY}"; then
    echo "❌ Error: oras login failed for ${ECR_REGISTRY}" >&2
    exit 1
  fi

  echo "✅ oras login succeeded"

  echo "Logging into ECR with docker: ${ECR_REGISTRY}"

  if ! aws ecr get-login-password --region "${AWS_REGION}" |
    docker login --username AWS --password-stdin "${ECR_REGISTRY}"; then
    echo "❌ Error: docker login failed for ${ECR_REGISTRY}" >&2
    exit 1
  fi

  echo "✅ docker login succeeded"
}

function ensureVertexBinary() {
  # Usage:
  #   ensureVertexBinary <version> [binary-path]
  #
  # Optional env vars:
  #   DOWNLOAD_BINARY=true    # skip prompt and download automatically
  #   DOWNLOAD_USER=spectro   # optional basic auth username
  #   DOWNLOAD_PASS=xxxxx     # optional basic auth password

  local version="${1:-${VERTEX_VERSION:-}}"

  if [[ -z "$version" ]]; then
    echo "❌ Error: version is required" >&2
    echo "Usage: ensureVertexBinary <version>" >&2
    exit 1
  fi

  local binary="${2:-${BINARY:-${SCRIPT_DIR:-.}/downloads/airgap-vertex-v${version}.bin}}"
  local base_url="https://software-private.spectrocloud.com/airgap-vertex"
  local filename="airgap-vertex-v${version}.bin"
  local url="${base_url}/${version}/${filename}"

  if [[ -f "$binary" ]]; then
    echo "✅ Binary found: ${binary}"

    if [[ ! -x "$binary" ]]; then
      echo "Binary is not executable. Fixing..."
      chmod +x "$binary"
    fi

    return 0
  fi

  echo "❌ Error: Binary not found: ${binary}" >&2
  echo "Download URL: ${url}"
  echo ""

  local answer=""

  if [[ "${DOWNLOAD_BINARY:-false}" == "true" ]]; then
    answer="y"
  else
    read -r -p "Would you like to download it now? [y/N]: " answer
  fi

  case "$answer" in
    y|Y|yes|YES)
      echo "Downloading ${filename}..."

      local binary_dir
      binary_dir="$(dirname "${binary}")"
      mkdir -p "${binary_dir}" ||
        fail "Failed to create binary download directory: ${binary_dir}"

      local curl_args=(
        -fL
        --connect-timeout 10
        --retry 3
        --retry-delay 5
        -o "$binary"
      )

      if [[ -n "${DOWNLOAD_USER:-}" && -n "${DOWNLOAD_PASS:-}" ]]; then
        curl_args+=(--user "${DOWNLOAD_USER}:${DOWNLOAD_PASS}")
      fi

      if ! curl "${curl_args[@]}" "$url"; then
        echo "❌ Error: failed to download binary from ${url}" >&2
        rm -f "$binary"
        exit 1
      fi

      chmod +x "$binary"
      echo "✅ Downloaded and made executable: ${binary}"
      ;;
    *)
      echo "❌ Binary is required. Exiting." >&2
      exit 1
      ;;
  esac
}
function detect_os() {
  local uname_s
  uname_s="$(uname -s 2>/dev/null || echo unknown)"

  case "$uname_s" in
    Darwin)
      echo "macos"
      ;;
    Linux)
      if grep -qi microsoft /proc/version 2>/dev/null; then
        echo "wsl"
      else
        echo "linux"
      fi
      ;;
    CYGWIN*|MINGW*|MSYS*)
      echo "windows"
      ;;
    *)
      echo "unknown"
      ;;
  esac
}

function print_prerequisite_install_instructions() {
  local os_type="$1"
  shift
  local tool

  echo ""
  echo "Installation guidance for ${os_type}:"
  for tool in "$@"; do
    case "${os_type}:${tool}" in
      macos:docker)
        echo "  Docker:"
        echo "    brew install --cask docker"
        echo "    Then start Docker Desktop."
        echo "    https://docs.docker.com/desktop/setup/install/mac-install/"
        ;;
      macos:oras)
        echo "  ORAS CLI v1.0.0 (exact version required):"
        echo "    Download the darwin archive for your architecture:"
        echo "    https://github.com/oras-project/oras/releases/tag/v1.0.0"
        ;;
      macos:jq)
        echo "  jq:"
        echo "    brew install jq"
        echo "    https://jqlang.org/download/"
        ;;
      macos:zip)
        echo "  zip:"
        echo "    macOS normally includes zip; otherwise run: brew install zip"
        ;;
      macos:unzip)
        echo "  unzip:"
        echo "    macOS normally includes unzip; otherwise run: brew install unzip"
        ;;
      macos:aws)
        echo "  AWS CLI v2:"
        echo "    Download and run https://awscli.amazonaws.com/AWSCLIV2.pkg"
        echo "    https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"
        ;;
      linux:docker)
        echo "  Docker Engine:"
        echo "    Follow the instructions for your Linux distribution:"
        echo "    https://docs.docker.com/engine/install/"
        ;;
      linux:oras)
        echo "  ORAS CLI v1.0.0 (exact version required):"
        echo "    Download the linux archive for your architecture:"
        echo "    https://github.com/oras-project/oras/releases/tag/v1.0.0"
        ;;
      linux:jq)
        echo "  jq:"
        echo "    Debian/Ubuntu: sudo apt-get update && sudo apt-get install -y jq"
        echo "    Fedora/RHEL:   sudo dnf install -y jq"
        echo "    https://jqlang.org/download/"
        ;;
      linux:zip|linux:unzip)
        echo "  ${tool}:"
        echo "    Debian/Ubuntu: sudo apt-get update && sudo apt-get install -y ${tool}"
        echo "    Fedora/RHEL:   sudo dnf install -y ${tool}"
        ;;
      linux:aws)
        echo "  AWS CLI v2:"
        echo "    Follow the architecture-specific installer instructions:"
        echo "    https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"
        ;;
      wsl:docker)
        echo "  Docker Desktop with the WSL 2 backend:"
        echo "    https://docs.docker.com/desktop/features/wsl/"
        ;;
      wsl:oras)
        echo "  ORAS CLI v1.0.0 inside WSL (exact version required):"
        echo "    Download the linux archive for your architecture:"
        echo "    https://github.com/oras-project/oras/releases/tag/v1.0.0"
        ;;
      wsl:jq)
        echo "  jq inside WSL:"
        echo "    sudo apt-get update && sudo apt-get install -y jq"
        echo "    https://jqlang.org/download/"
        ;;
      wsl:zip|wsl:unzip)
        echo "  ${tool} inside WSL:"
        echo "    sudo apt-get update && sudo apt-get install -y ${tool}"
        ;;
      wsl:aws)
        echo "  AWS CLI v2 inside WSL:"
        echo "    https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"
        ;;
      windows:docker)
        echo "  Docker Desktop:"
        echo "    https://docs.docker.com/desktop/setup/install/windows-install/"
        ;;
      windows:oras)
        echo "  ORAS CLI v1.0.0 (exact version required):"
        echo "    Install the Windows archive from:"
        echo "    https://github.com/oras-project/oras/releases/tag/v1.0.0"
        ;;
      windows:jq)
        echo "  jq:"
        echo "    winget install jqlang.jq"
        echo "    https://jqlang.org/download/"
        ;;
      windows:aws)
        echo "  AWS CLI v2:"
        echo "    https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"
        ;;
      windows:zip|windows:unzip)
        echo "  ${tool}:"
        echo "    Install a compatible zip utility and add it to PATH."
        ;;
      *:docker)
        echo "  Docker: https://docs.docker.com/get-started/get-docker/"
        ;;
      *:oras)
        echo "  ORAS: https://oras.land/docs/installation/"
        ;;
      *:jq)
        echo "  jq: https://jqlang.org/download/"
        ;;
      *:zip|*:unzip)
        echo "  ${tool}: install it with your operating system package manager."
        ;;
      *:aws)
        echo "  AWS CLI v2: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"
        ;;
    esac
  done
}

function check_prerequisites() {
  local os_type="${1:-$(detect_os)}"
  local tool
  local aws_version_output=""
  local docker_daemon_ready=true
  local line
  local oras_version=""
  local oras_version_output=""
  local -a problem_tools=()

  echo "Checking required command-line tools for ${os_type}..."
  for tool in docker oras zip unzip jq aws; do
    if command -v "${tool}" >/dev/null 2>&1; then
      echo "✅ ${tool}: $(command -v "${tool}")"
    else
      echo "❌ ${tool}: not found" >&2
      problem_tools+=("${tool}")
    fi
  done

  if command -v aws >/dev/null 2>&1; then
    aws_version_output="$(aws --version 2>&1 || true)"
    if [[ "${aws_version_output}" =~ aws-cli/2\. ]]; then
      echo "✅ AWS CLI major version: 2"
    else
      echo "❌ AWS CLI v2 is required; found: ${aws_version_output:-unknown version}" >&2
      problem_tools+=("aws")
    fi
  fi

  if command -v oras >/dev/null 2>&1; then
    oras_version_output="$(oras version 2>&1 || true)"
    while IFS= read -r line; do
      if [[ "${line}" =~ ^Version:[[:space:]]*v?([^[:space:]]+)[[:space:]]*$ ]]; then
        oras_version="${BASH_REMATCH[1]}"
        break
      fi
    done <<<"${oras_version_output}"
    if [[ "${oras_version}" == "1.0.0" ]]; then
      echo "✅ ORAS CLI version: ${oras_version}"
    else
      echo "⚠️  WARNING: ORAS CLI v1.0.0 is recommended; found: ${oras_version:-unknown version}" >&2
    fi
  fi

  if command -v docker >/dev/null 2>&1 &&
    ! docker info >/dev/null 2>&1; then
    docker_daemon_ready=false
    echo "❌ docker: CLI is installed, but the Docker daemon is unavailable" >&2
  fi

  if ((${#problem_tools[@]} > 0)); then
    print_prerequisite_install_instructions "${os_type}" "${problem_tools[@]}"
  fi

  if [[ "${docker_daemon_ready}" != "true" ]]; then
    echo ""
    case "${os_type}" in
      macos)
        echo "Start Docker Desktop (for example: open -a Docker), then retry."
        ;;
      linux)
        echo "Start Docker (for example: sudo systemctl start docker), then retry."
        ;;
      wsl)
        echo "Start Docker Desktop with WSL integration enabled, then retry."
        ;;
      *)
        echo "Start the Docker daemon, then retry."
        ;;
    esac
  fi

  if ((${#problem_tools[@]} > 0)) ||
    [[ "${docker_daemon_ready}" != "true" ]]; then
    echo ""
    echo "Prerequisite check failed. Install or start the items above and rerun."
    return 1
  fi

  echo "✅ All required command-line prerequisites are available."
}

function enable_docker_push_skip_if_exists() {
  validateVar ECR_REGISTRY
  validateVar AWS_REGION

  local registry_id
  registry_id="${ECR_REGISTRY%%.*}"
  if [[ ! "${registry_id}" =~ ^[0-9]{12}$ ]]; then
    fail "Unable to determine the 12-digit AWS account ID from ECR_REGISTRY: ${ECR_REGISTRY}"
  fi

  local real_docker
  real_docker="$(command -v docker)"

  if [[ -z "${real_docker}" ]]; then
    fail "docker command not found"
  fi

  local wrapper_dir
  wrapper_dir="$(mktemp -d)"

  export REAL_DOCKER_BIN="${real_docker}"
  export ECR_REGISTRY
  export ECR_REGISTRY_ID="${registry_id}"
  export AWS_REGION
  export PATH="${wrapper_dir}:${PATH}"

  cat > "${wrapper_dir}/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

real_docker="${REAL_DOCKER_BIN:?REAL_DOCKER_BIN is not set}"

parse_ecr_image_ref() {
  local image_ref="$1"
  local registry="${ECR_REGISTRY:?ECR_REGISTRY is not set}"

  # Only handle pushes to our ECR registry.
  if [[ "${image_ref}" != "${registry}/"* ]]; then
    return 1
  fi

  local remainder
  remainder="${image_ref#${registry}/}"

  # Remove digest if present.
  remainder="${remainder%%@*}"

  local repo
  local tag

  # If no tag was specified, Docker defaults to latest.
  if [[ "${remainder##*/}" == *":"* ]]; then
    repo="${remainder%:*}"
    tag="${remainder##*:}"
  else
    repo="${remainder}"
    tag="latest"
  fi

  if [[ -z "${repo}" || -z "${tag}" ]]; then
    return 1
  fi

  printf '%s\t%s\n' "${repo}" "${tag}"
}

ecr_image_tag_exists() {
  local repo="$1"
  local tag="$2"
  local aws_output

  if aws_output="$(
    aws ecr describe-images \
      --registry-id "${ECR_REGISTRY_ID:?ECR_REGISTRY_ID is not set}" \
      --region "${AWS_REGION:?AWS_REGION is not set}" \
      --repository-name "${repo}" \
      --image-ids "imageTag=${tag}" \
      --query 'imageDetails[0].imageDigest' \
      --output text 2>&1
  )"; then
    return 0
  fi

  case "${aws_output}" in
    *ImageNotFoundException*|*RepositoryNotFoundException*)
      return 1
      ;;
    *)
      echo "Unable to check whether the image tag exists in ECR; refusing to push:" >&2
      echo "  ${ECR_REGISTRY}/${repo}:${tag}" >&2
      printf '%s\n' "${aws_output}" >&2
      return 2
      ;;
  esac
}

push_ecr_image_with_retries() {
  local max_attempts="${ECR_PUSH_MAX_ATTEMPTS:-3}"
  local retry_delay="${ECR_PUSH_RETRY_DELAY_SECONDS:-5}"
  local attempt=1
  local push_status

  while ((attempt <= max_attempts)); do
    if "${real_docker}" "$@"; then
      return 0
    else
      push_status=$?
    fi

    if ((attempt == max_attempts)); then
      echo "Docker push failed after ${max_attempts} attempts." >&2
      return "${push_status}"
    fi

    echo "Docker push failed (attempt ${attempt}/${max_attempts}); retrying in ${retry_delay} seconds..." >&2
    sleep "${retry_delay}"
    attempt=$((attempt + 1))
  done
}

# Intercept:
#   docker push <image>
if [[ "${1:-}" == "push" ]]; then
  image_ref="${!#}"

  parsed="$(parse_ecr_image_ref "${image_ref}" || true)"

  if [[ -n "${parsed}" ]]; then
    IFS=$'\t' read -r repo tag <<< "${parsed}"

    if ecr_image_tag_exists "${repo}" "${tag}"; then
      echo "Image already exists in ECR. Skipping push:"
      echo "  ${image_ref}"
      exit 0
    else
      ecr_check_status=$?
      if [[ ${ecr_check_status} -ne 1 ]]; then
        exit "${ecr_check_status}"
      fi
    fi

    echo "Image does not exist in ECR. Pushing:"
    echo "  ${image_ref}"
    push_ecr_image_with_retries "$@"
    exit $?
  fi
fi

exec "${real_docker}" "$@"
EOF

  chmod +x "${wrapper_dir}/docker"

  echo "Docker push skip wrapper enabled."
  echo "Real docker: ${real_docker}"
  echo "Wrapper dir: ${wrapper_dir}"
}
