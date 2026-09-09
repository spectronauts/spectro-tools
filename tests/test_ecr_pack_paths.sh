#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
source "${PROJECT_DIR}/config/common-functions.sh"

failures=0

assert_equal() {
  local description="$1"
  local expected="$2"
  local actual="$3"

  if [[ "${actual}" == "${expected}" ]]; then
    printf 'PASS: %s\n' "${description}"
    return
  fi

  printf 'FAIL: %s\n  expected: %s\n  actual:   %s\n' \
    "${description}" "${expected}" "${actual}" >&2
  failures=$((failures + 1))
}

registry="103448924380.dkr.ecr.us-gov-west-1.amazonaws.com"
pack_registry="$(build_palette_pack_registry "${registry}" "cuff-airgap" "spectro-packs")"

assert_equal \
  "reported pack destination contains one spectro-packs segment" \
  "${registry}/cuff-airgap/spectro-packs/archive/cni-aws-vpc-eks-helm:1.22.3" \
  "${pack_registry}/spectro-packs/archive/cni-aws-vpc-eks-helm:1.22.3"

assert_equal \
  "empty pack base uses the configured content path" \
  "${registry}/cuff-airgap" \
  "$(build_palette_pack_registry "${registry}" "cuff-airgap" "")"

assert_equal \
  "configured spectro-packs is not duplicated" \
  "${registry}/cuff-airgap" \
  "$(build_palette_pack_registry "${registry}" "cuff-airgap" "spectro-packs")"

assert_equal \
  "spectro-packs suffix in the content path is not duplicated" \
  "${registry}/cuff-airgap" \
  "$(build_palette_pack_registry "${registry}" "cuff-airgap/spectro-packs" "")"

assert_equal \
  "custom pack prefix is preserved" \
  "${registry}/cuff-airgap/custom-packs" \
  "$(build_palette_pack_registry "${registry}/" "/cuff-airgap/" "/custom-packs/")"

assert_equal \
  "empty content and pack paths do not add a trailing slash" \
  "${registry}" \
  "$(build_palette_pack_registry "${registry}/" "" "")"

if ((failures > 0)); then
  printf 'FAILED: %d pack path test(s) failed.\n' "${failures}" >&2
  exit 1
fi

printf 'All ECR pack path tests passed.\n'
