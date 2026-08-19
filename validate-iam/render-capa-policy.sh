#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
COMMON_CONFIG="${SCRIPT_DIR}/../config/common-config.sh"
COMMON_FUNCTIONS="${SCRIPT_DIR}/../config/common-functions.sh"
# shellcheck source=../config/common-config.sh
source "${COMMON_CONFIG}"
# shellcheck source=../config/common-functions.sh
source "${COMMON_FUNCTIONS}"
CONFIG_FILE="${CONFIG_FILE:-}"
TEMPLATE_FILE="${SCRIPT_DIR}/policies/capa-passrole-policy.template.json"

if [[ -n "${CONFIG_FILE}" ]]; then
  if [[ ! -f "${CONFIG_FILE}" ]]; then
    echo "ERROR: Configuration override file not found: ${CONFIG_FILE}" >&2
    exit 1
  fi
  # shellcheck source=/dev/null
  source "${CONFIG_FILE}"
fi
if [[ -n "${AWS_PROFILE}" ]]; then
  export AWS_PROFILE
else
  unset AWS_PROFILE
fi

case "$PARTITION" in
  aws)         ARN_PREFIX="arn:aws" ;;
  aws-us-gov)  ARN_PREFIX="arn:aws-us-gov" ;;
  aws-iso)     ARN_PREFIX="arn:aws-iso" ;;
  aws-iso-b)   ARN_PREFIX="arn:aws-iso-b" ;;
  *)
    echo "ERROR: Unknown PARTITION '$PARTITION'" >&2
    exit 1
    ;;
esac

if [[ -z "$ACCOUNT_ID" ]]; then
  ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
fi

CAPA_ROLE_PATTERN="${ARN_PREFIX}:iam::${ACCOUNT_ID}:role/*.cluster-api-provider-aws.sigs.k8s.io"

jq --arg resource "$CAPA_ROLE_PATTERN" \
  '(.Statement[].Resource) = [$resource]' \
  "$TEMPLATE_FILE"
