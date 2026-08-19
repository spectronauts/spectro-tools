#!/bin/bash
# Deletes ECR repositories at or below ECR_DELETE_PATH from ../config/common-config.sh.
#
# Prerequisites:
#   - AWS CLI v2 configured with credentials that have ecr:DescribeRepositories + ecr:DeleteRepository
#   - aws configure --profile <your-govcloud-profile>  (or set AWS_PROFILE / AWS_ACCESS_KEY_ID etc.)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="$(cd -- "${SCRIPT_DIR}/../config" && pwd)"
# shellcheck source=../config/common-config.sh
source "${CONFIG_DIR}/common-config.sh"
# shellcheck source=../config/common-functions.sh
source "${CONFIG_DIR}/common-functions.sh"

: "${AWS_ACCOUNT:?AWS_ACCOUNT must be set in ../config/common-config.sh}"
: "${AWS_REGION:?AWS_REGION must be set in ../config/common-config.sh}"
: "${ECR_REGISTRY:?ECR_REGISTRY must be set in ../config/common-config.sh}"
: "${ECR_DELETE_PATH:?ECR_DELETE_PATH must be set in ../config/common-config.sh}"

PREFIX="${ECR_DELETE_PATH#/}"
PREFIX="${PREFIX%/}"
if [[ ! "${PREFIX}" =~ ^[a-z0-9]+([._/-][a-z0-9]+)*$ ]]; then
  echo "ERROR: ECR_DELETE_PATH is not a valid ECR repository prefix: ${ECR_DELETE_PATH}" >&2
  echo "Set it relative to ECR_REGISTRY, for example: cuff-airgap/spectro-packs" >&2
  exit 2
fi
ECR_DELETE_PATH="${ECR_REGISTRY}/${PREFIX}"

# Optional: set a named profile if needed
# export AWS_PROFILE="govcloud"

echo "Deletion scope:"
echo "  Account:           ${AWS_ACCOUNT}"
echo "  Region:            ${AWS_REGION}"
echo "  Repository prefix: ${PREFIX}"
echo "  Full ECR path:     ${ECR_DELETE_PATH}"
echo ""
echo "Only the repository '${PREFIX}' and repositories below '${PREFIX}/' are eligible."
echo ""
echo "==> Fetching repositories in the configured deletion scope..."

REPOS=$(aws ecr describe-repositories \
  --region "${AWS_REGION}" \
  --query "repositories[?repositoryName == '${PREFIX}' || starts_with(repositoryName, '${PREFIX}/')].repositoryName" \
  --output text)

if [[ -z "${REPOS}" ]]; then
  echo "No repositories found at or below '${ECR_DELETE_PATH}'. Nothing to delete."
  exit 0
fi

echo ""
echo "The following repositories will be DELETED:"
for REPO in ${REPOS}; do
  echo "  - ${ECR_REGISTRY}/${REPO}"
done

echo ""
echo "This permanently deletes every listed repository and all images in it."
read -rp "Type the exact deletion path to continue (${ECR_DELETE_PATH}): " CONFIRM
if [[ "${CONFIRM}" != "${ECR_DELETE_PATH}" ]]; then
  echo "Aborted: confirmation did not exactly match '${ECR_
DELETE_PATH}'."
  exit 1
fi

echo ""
for REPO in ${REPOS}; do
  echo "==> Deleting repository: ${ECR_REGISTRY}/${REPO}"
  aws --no-cli-pager ecr delete-repository \
    --region "${AWS_REGION}" \
    --repository-name "${REPO}" \
    --force   # --force also deletes all images inside the repo
  echo "    Deleted: ${ECR_REGISTRY}/${REPO}"
done

echo ""
echo "Done. All repositories at or below '${ECR_DELETE_PATH}' have been deleted."
