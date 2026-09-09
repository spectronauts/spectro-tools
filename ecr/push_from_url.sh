#!/bin/bash
# download and push bundles
# Usage: ./push_from_url.sh <zst-urls-file>
# Example: ./push_from_url.sh ./zst_urls.txt
# Build a bundle, copy urls to file, then download and push to ECR using this script.
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="$(cd -- "${SCRIPT_DIR}/../config" && pwd)"
source "${CONFIG_DIR}/common-config.sh"
source "${CONFIG_DIR}/common-functions.sh"

os_type="$(detect_os)"
if [[ "${os_type}" == "macos" ]]; then
  echo "ERROR: push_from_url.sh is not supported on macOS because the Palette CLI is not available as a compatible multi-architecture binary." >&2
  echo "Run this script from a supported Linux environment instead." >&2
  exit 1
fi

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <zst-urls-file>" >&2
  exit 2
fi

BUNDLE_URL_FILE="$1"
if [[ ! -f "${BUNDLE_URL_FILE}" ]]; then
  echo "Error: URL file '${BUNDLE_URL_FILE}' not found." >&2
  exit 1
fi

BUNDLE_URL_DIR="$(cd "$(dirname "${BUNDLE_URL_FILE}")" && pwd)"
BUNDLE_URL_FILE="${BUNDLE_URL_DIR}/$(basename "${BUNDLE_URL_FILE}")"
BUNDLE_DIR="${BUNDLE_URL_DIR}"
DOWNLOAD_DIR="${BUNDLE_DIR}/downloads"
mkdir -p "${DOWNLOAD_DIR}"

validateVar AWS_ACCOUNT
validateVar AWS_REGION
validateVar ECR_BASE_CONTENT_PATH warn || true
validateVar ECR_IMAGE_BASE warn || true
validateVar ECR_PACK_BASE warn || true
validateVar ECR_REGISTRY
validateVar DOWNLOAD_USER fatal mask
validateVar DOWNLOAD_PASS fatal mask

export BUNDLE_DIR
export BUNDLE_URL_FILE
export PACK_REGISTRY
PACK_REGISTRY="$(build_palette_pack_registry "${ECR_REGISTRY}" "${ECR_BASE_CONTENT_PATH}" "${ECR_PACK_BASE}")"


echo "==> Downloading all .zst bundles from ${BUNDLE_URL_FILE} to ${DOWNLOAD_DIR}"

echo "Reading URLs from: $BUNDLE_URL_FILE"
echo ""

while IFS= read -r url; do
  # Skip empty lines and lines starting with #
  [[ -z "$url" || "$url" == \#* ]] && continue

  filename="${url##*/}"
  dest="${DOWNLOAD_DIR}/${filename}"

  # ── Skip if file already exists ──────────────────────────────────────────────
  if [[ -f "$dest" ]]; then
    echo "SKIP  $filename (already exists in ${DOWNLOAD_DIR})"
    echo ""
    continue
  fi

  echo "Downloading: $filename"
  echo "  From: $url"
  echo "  To:   $dest"
  curl -L -u "${DOWNLOAD_USER}:${DOWNLOAD_PASS}" -o "$dest" "$url"
  echo ""
done < "$BUNDLE_URL_FILE"

echo "All downloads complete!"

echo "Validating downloaded files in ${DOWNLOAD_DIR}..."
if [[ ! -f "${DOWNLOAD_DIR}/spectro_public_key.pem" ]]; then
  echo "ERROR: Required public key not found: ${DOWNLOAD_DIR}/spectro_public_key.pem" >&2
  echo "Include spectro_public_key.pem in the downloads directory before running this script." >&2
  exit 1
fi

echo ""

echo "Verifying signatures..."
echo ""

passed=0
failed=0
verified_bundles=()
verification_failures=()

while IFS= read -r url; do
  [[ -z "$url" || "$url" == \#* ]] && continue

  filename="${url##*/}"

  # Only process .zst files; find the matching .sig.bin
  if [[ "$filename" == *.zst ]]; then
    sigfile="${filename%.zst}.sig.bin"

    zst_path="${DOWNLOAD_DIR}/${filename}"
    sig_path="${DOWNLOAD_DIR}/${sigfile}"

    if [[ ! -f "$zst_path" ]]; then
      echo "FAIL  $filename (file not found: $zst_path)"
      failed=$((failed + 1))
      verification_failures+=("${filename}: bundle file not found")
      continue
    fi

    if [[ ! -f "$sig_path" ]]; then
      echo "FAIL  $filename (signature not found: $sig_path)"
      failed=$((failed + 1))
      verification_failures+=("${filename}: signature not found")
      continue
    fi

    if result="$(
      openssl dgst -sha256 \
        -verify "${DOWNLOAD_DIR}/spectro_public_key.pem" \
        -signature "$sig_path" \
        "$zst_path" 2>&1
    )"; then
      echo "OK    $filename"
      passed=$((passed + 1))
      verified_bundles+=("${zst_path}")
    else
      echo "FAIL  $filename ($result)"
      failed=$((failed + 1))
      verification_failures+=("${filename}: ${result}")
    fi
  fi
done < "$BUNDLE_URL_FILE"

echo ""
echo "Results: $passed passed, $failed failed"

if ((${#verification_failures[@]} > 0)); then
  echo "Verification failures:"
  for verification_failure in "${verification_failures[@]}"; do
    echo "  - ${verification_failure}"
  done
fi

if ((${#verified_bundles[@]} == 0)); then
  echo "ERROR: No verified .zst bundles are available to push." >&2
  exit 1
fi

echo "==> Authenticating to ECR..."

palette content registry-login \
  --registry ${ECR_REGISTRY} \
  --username AWS \
  --password "$(aws ecr get-login-password \
  --region ${AWS_REGION})"

echo "==> Pushing all .zst bundles from ${DOWNLOAD_DIR} to ${PACK_REGISTRY}"

successful_pushes=0
push_failures=()

for bundle in "${verified_bundles[@]}"; do
  echo "--> Pushing: ${bundle}"
  if palette content push \
    --file "${bundle}" \
    --registry "${PACK_REGISTRY}" \
    --insecure; then
    successful_pushes=$((successful_pushes + 1))
    echo "--> Push succeeded: ${bundle}"
  else
    push_rc=$?
    push_failures+=("${bundle} (exit code ${push_rc})")
    echo "ERROR: Push failed for ${bundle} with exit code ${push_rc}. Continuing with the remaining verified bundles." >&2
  fi
done

echo ""
echo "==> Bundle push summary"
echo "    Verified:        ${passed}"
echo "    Verification failures: ${failed}"
echo "    Push succeeded:  ${successful_pushes}"
echo "    Push failed:     ${#push_failures[@]}"

if ((${#push_failures[@]} > 0)); then
  echo "Push failures:"
  for push_failure in "${push_failures[@]}"; do
    echo "  - ${push_failure}"
  done
fi

if ((failed > 0 || ${#push_failures[@]} > 0)); then
  echo "ERROR: Bundle processing completed with failures." >&2
  exit 1
fi

echo "==> All bundles pushed successfully."
unset BUNDLE_DIR
unset BUNDLE_URL_FILE
unset DOWNLOAD_DIR
unset PACK_REGISTRY
