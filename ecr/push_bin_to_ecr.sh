#! /bin/bash
# Usage: ./push_bin_to_ecr.sh [version] [--skip-extraction|-s]
# Example: ./push_bin_to_ecr.sh 4.9.18
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="$(cd -- "${SCRIPT_DIR}/../config" && pwd)"
source "${CONFIG_DIR}/common-config.sh"
source "${CONFIG_DIR}/common-functions.sh"

function usage() {
  echo "Usage: $0 [version] [--skip-extraction|-s]"
  echo ""
  echo "Examples:"
  echo "  $0"
  echo "  $0 4.9.18"
  echo "  $0 4.9.18 --skip-extraction"
  echo "  $0 4.9.18 -s"
}

configured_vertex_version="${VERTEX_VERSION:-}"
default_binary="${SCRIPT_DIR}/downloads/airgap-vertex-v${configured_vertex_version}.bin"
default_airgap_dir="${SCRIPT_DIR}/downloads/spectroairgap-${configured_vertex_version}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -s|--skip-extraction) SKIP_EXTRACTION=true ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
    *) [[ -z "${VERSION:-}" ]] && VERSION="$1" || { echo "Unexpected argument: $1" >&2; usage >&2; exit 1; } ;;
  esac
  shift
done

if [[ -n "${VERSION:-}" ]]; then
  VERTEX_VERSION="${VERSION}"

  if [[ "${BINARY:-}" == "${default_binary}" ]]; then
    BINARY="${SCRIPT_DIR}/downloads/airgap-vertex-v${VERTEX_VERSION}.bin"
  fi

  if [[ "${AIRGAP_DIR:-}" == "${default_airgap_dir}" ]]; then
    AIRGAP_DIR="${SCRIPT_DIR}/downloads/spectroairgap-${VERTEX_VERSION}"
  fi
fi

validateVar VERTEX_VERSION
timestamp=$(date +%Y%m%d%H%M%S)
LOG_DIR="${SCRIPT_DIR}/logs"
LOG_FILE="${LOG_DIR}/push_bin_to_ecr-${VERTEX_VERSION}-${timestamp}.log"
mkdir -p "${LOG_DIR}"
touch "${LOG_FILE}"
export LOG_FILE
exec > >(tee -a "${LOG_FILE}") 2>&1
date
echo "Log file: ${LOG_FILE}"
os_type=$(detect_os)


#Step 1: Validate Variables
###########################
print_boxed "Step #1: Validating Variables needed for this script"
validateVar VERTEX_VERSION
validateVar AWS_ACCOUNT
validateVar AWS_REGION
validateVar ECR_BASE_CONTENT_PATH warn || true
validateVar ECR_IMAGE_BASE warn || true
validateVar ECR_PACK_BASE warn || true
validateVar ECR_REGISTRY
validateVar DOWNLOAD_USER warn mask || true
validateVar DOWNLOAD_PASS warn mask || true
validateVar SCRIPT_DIR
validateVar AIRGAP_DIR
validateVar BINARY
validateVar SKIP_EXTRACTION warn || true
validateVar os_type

check_prerequisites "${os_type}"

#Step 2: Authenticate to ECR
############################
print_boxed "Step #2: Authenticating ORAS and Docker to ECR"
ecrLogin

# Enable docker push skip logic after auth.
enable_docker_push_skip_if_exists

#Step 3: Setup Env and extract the binary
#########################################

print_boxed "Step #3: Extracting the binary and setting up env vars"
# exporting variables for the binary to use
export ECR_IMAGE_REGISTRY=${ECR_REGISTRY}
export ECR_IMAGE_BASE="${ECR_BASE_CONTENT_PATH:+${ECR_BASE_CONTENT_PATH%/}/}${ECR_IMAGE_BASE#/}"
export ECR_IMAGE_REGISTRY_REGION=${AWS_REGION}
export ECR_PACK_REGISTRY=${ECR_REGISTRY}
airgap_pack_base="${ECR_BASE_CONTENT_PATH:+${ECR_BASE_CONTENT_PATH%/}/}${ECR_PACK_BASE#/}"
airgap_pack_base="${airgap_pack_base%/}"
if [[ "${airgap_pack_base}" == "spectro-packs" ]]; then
  airgap_pack_base=""
elif [[ "${airgap_pack_base}" == */spectro-packs ]]; then
  airgap_pack_base="${airgap_pack_base%/spectro-packs}"
fi
export ECR_PACK_BASE="${airgap_pack_base}"
export ECR_PACK_REGISTRY_REGION=${AWS_REGION}
export SCRIPT_DIR="${SCRIPT_DIR}"
export AIRGAP_DIR="${AIRGAP_DIR}"
export ECR_IMAGE_REGISTRY_TYPE="${ECR_IMAGE_REGISTRY_TYPE}"
export ECR_PACK_REGISTRY_TYPE="${ECR_PACK_REGISTRY_TYPE}"
export BINARY="${BINARY}"
echo "ECR configuration:"
echo "  ECR_IMAGE_REGISTRY=${ECR_IMAGE_REGISTRY}"
echo "  ECR_IMAGE_BASE=${ECR_IMAGE_BASE}"
echo "  ECR_IMAGE_REGISTRY_REGION=${ECR_IMAGE_REGISTRY_REGION}"
echo "  ECR_IMAGE_REGISTRY_TYPE=${ECR_IMAGE_REGISTRY_TYPE}"
echo "  ECR_PACK_REGISTRY=${ECR_PACK_REGISTRY}"
echo "  ECR_PACK_BASE=${ECR_PACK_BASE}"
echo "  ECR_PACK_REGISTRY_REGION=${ECR_PACK_REGISTRY_REGION}"
echo "  ECR_PACK_REGISTRY_TYPE=${ECR_PACK_REGISTRY_TYPE}"

# Checking for the binary and extracting it if needed
if [[ "${SKIP_EXTRACTION}" == "false" ]]; then
  ensureVertexBinary "${VERTEX_VERSION}" "${BINARY}"
  extract_binary "${BINARY}" "${AIRGAP_DIR}"
else
  echo "Skipping binary extraction."
  if [[ ! -d "${AIRGAP_DIR}" ]]; then
    fail "Airgap directory not found: ${AIRGAP_DIR}. Cannot use --skip-extraction unless it already exists."
  fi
fi

patch_functions_file "${AIRGAP_DIR}" "${os_type}"

#Step 4: Setup Env and extract the binary
#########################################

print_boxed "Step #4: Pushing Packs and Images to Airgapped Private ECR's"
echo "Starting airgap push for version: ${VERTEX_VERSION}"
echo "Binary: ${BINARY}"
echo "Registry: ${ECR_REGISTRY}"
echo "Packs Push to: ${ECR_PACK_REGISTRY%/}/${ECR_PACK_BASE:+${ECR_PACK_BASE%/}/}spectro-packs"
echo "Images Push to: ${ECR_IMAGE_REGISTRY}/${ECR_IMAGE_BASE%/}"
echo ""

read -r -p "Continue with the airgap push to these destinations? [y/N]: " PUSH_CONFIRM
case "${PUSH_CONFIRM}" in
  y|Y|yes|YES)
    echo "Continuing with the airgap push."
    ;;
  *)
    echo "Airgap push aborted."
    exit 0
    ;;
esac
echo ""

# Run the binary, capture output, auto-create any missing repos, retry ---
pushd "${AIRGAP_DIR}" >/dev/null

run_apply_script_with_repo_retry "apply_pack.sh"
run_apply_script_with_repo_retry "apply_patch.sh"

popd >/dev/null

if [[ "${SKIP_EXTRACTION}" == "false" ]]; then
  echo "Removing extracted directory: ${AIRGAP_DIR}"
  rm -rf "${AIRGAP_DIR}"
else
  echo "Preserving extracted directory because --skip-extraction was used: ${AIRGAP_DIR}"
fi

echo "Airgap push completed successfully."

#IDEABOARD: 
# export cluster profile and create script to parse, download packs, and push to ECR.
# take copy all urls command from artifact studio, download packs and push to ECR.
