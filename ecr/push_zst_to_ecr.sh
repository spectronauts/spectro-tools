#!/bin/bash
# push_zst_to_ecr.sh
# Prerequisites: palette CLI installed and configured, AWS CLI installed and configured, ../config/common-config.sh
# Usage: ./push_zst_to_ecr.sh <bundle-dir>
# Example: ./push_zst_to_ecr.sh ./bundles
# Used to push all .zst bundles from a directory to ECR using the palette content push command.

set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="$(cd -- "${SCRIPT_DIR}/../config" && pwd)"
source "${CONFIG_DIR}/common-config.sh"
source "${CONFIG_DIR}/common-functions.sh"

os_type="$(detect_os)"
if [[ "${os_type}" == "macos" ]]; then
  echo "ERROR: push_zst_to_ecr.sh is not supported on macOS because the Palette CLI is not available as a compatible multi-architecture binary." >&2
  echo "Run this script from a supported Linux environment instead." >&2
  exit 1
fi

validateVar AWS_ACCOUNT
validateVar AWS_REGION
validateVar ECR_BASE_CONTENT_PATH warn || true
validateVar ECR_IMAGE_BASE warn || true
validateVar ECR_PACK_BASE warn || true
validateVar ECR_REGISTRY

BUNDLE_DIR="${1:?Usage: $0 <bundle-dir>}" || echo "Bundle Directory: ${BUNDLE_DIR}"
BASE_PATH="${ECR_BASE_CONTENT_PATH:+${ECR_BASE_CONTENT_PATH%/}/}${ECR_PACK_BASE#/}" || echo "Base Content Path: ${BASE_PATH}"

shopt -s nullglob
bundles=("${BUNDLE_DIR}"/*.zst)
if ((${#bundles[@]} == 0)); then
  echo "No .zst files found in ${BUNDLE_DIR}" >&2
  exit 1
fi

echo "==> Authenticating to ECR..."

palette content registry-login \
  --registry ${ECR_REGISTRY} \
  --username AWS \
  --password "$(aws ecr get-login-password \
  --region ${AWS_REGION})"

echo "==> Pushing all .zst bundles from ${BUNDLE_DIR} to ${ECR_REGISTRY}/${BASE_PATH}"

failed_bundles=()
successful_pushes=0

for bundle in "${bundles[@]}"; do
  echo "--> Pushing: ${bundle}"
  if palette content push \
    --file "${bundle}" \
    --registry "${ECR_REGISTRY}/${BASE_PATH}" \
    --insecure; then
    successful_pushes=$((successful_pushes + 1))
    echo "--> Push succeeded: ${bundle}"
  else
    push_rc=$?
    failed_bundles+=("${bundle} (exit code ${push_rc})")
    echo "ERROR: Push failed for ${bundle} with exit code ${push_rc}. Continuing with the remaining bundles." >&2
  fi
done

if ((${#failed_bundles[@]} > 0)); then
  echo ""
  echo "==> Bundle push completed with failures."
  echo "    Successful: ${successful_pushes}"
  echo "    Failed:     ${#failed_bundles[@]}"
  echo "Failed bundles:"
  for failed_bundle in "${failed_bundles[@]}"; do
    echo "  - ${failed_bundle}"
  done
  exit 1
fi

echo "==> All bundles pushed successfully."
