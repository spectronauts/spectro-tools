#!/usr/bin/env bash
# =============================================================================
# validate-palette-vertex-iam.sh
#
# Validates IAM permissions required to deploy Palette VerteX onto an AWS EKS
# cluster using static secrets, STS, or EKS Pod Identity. Supports commercial
# (aws), GovCloud (aws-us-gov), and isolated partitions. Validates:
#   - Core or minimum EKS permissions (dynamic + static placement)
#   - Pod Identity roles, associations, and runtime injection when selected
#   - STS assume-role and session-tagging capabilities when selected
#   - The current IAM user when static secret authentication is selected
#   - OIDC provider management
#   - Profile-aware Palette-role EKS add-on management
#
# Usage:
#   # Edit ../config/common-config.sh for your environment
#   ./validate-iam.sh [secret|sts|pod-identity]
#
# Optional per-run override:
#   CONFIG_FILE=/path/to/validate-iam.conf ./validate-iam.sh
# =============================================================================

set -euo pipefail

# ─── Load configuration ─────────────────────────────────────────────────────
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
COMMON_CONFIG="${SCRIPT_DIR}/../config/common-config.sh"
COMMON_FUNCTIONS="${SCRIPT_DIR}/../config/common-functions.sh"
# shellcheck source=../config/common-config.sh
source "${COMMON_CONFIG}"
# shellcheck source=../config/common-functions.sh
source "${COMMON_FUNCTIONS}"
CONFIG_FILE="${CONFIG_FILE:-}"

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

if [[ "$#" -gt 1 ]]; then
  echo "Usage: $0 [secret|sts|pod-identity]" >&2
  exit 2
fi
AUTH_MODE="${1:-${AUTH_MODE:-}}"
PLACEMENT_MODE="${PLACEMENT_MODE:-dynamic}"
# Existing configurations predate PERMISSION_PROFILE. Derive the matching
# minimum profile so they retain their previous dynamic/static intent.
PERMISSION_PROFILE="${PERMISSION_PROFILE:-minimum-${PLACEMENT_MODE}}"

# ─── Colour helpers ──────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

pass()  { echo -e "  ${GREEN}[PASS]${RESET} $*"; }
fail()  {
  local message="$1"
  local remediation="${2:-}"
  echo -e "  ${RED}[FAIL]${RESET} $message"
  if [[ -n "$remediation" ]]; then
    echo -e "         ${YELLOW}FIX:${RESET} $remediation"
  fi
  FAILURES=$((FAILURES+1))
}
warn()  { echo -e "  ${YELLOW}[WARN]${RESET} $*"; }
info()  { echo -e "  ${CYAN}[INFO]${RESET} $*"; }
header(){ echo -e "\n${BOLD}${CYAN}══════════════════════════════════════════${RESET}"; \
          echo -e "${BOLD}${CYAN}  $*${RESET}"; \
          echo -e "${BOLD}${CYAN}══════════════════════════════════════════${RESET}"; }

FAILURES=0

case "$AUTH_MODE" in
  secret|sts|pod-identity) ;;
  *)
    echo -e "${RED}ERROR: Unknown AUTH_MODE '$AUTH_MODE'. Valid: secret | sts | pod-identity${RESET}"
    exit 1
    ;;
esac

case "$PLACEMENT_MODE" in
  dynamic|static) ;;
  *)
    echo -e "${RED}ERROR: Unknown PLACEMENT_MODE '$PLACEMENT_MODE'. Valid: dynamic | static${RESET}"
    exit 1
    ;;
esac

case "$PERMISSION_PROFILE" in
  core|minimum-dynamic|minimum-static) ;;
  *)
    echo -e "${RED}ERROR: Unknown PERMISSION_PROFILE '$PERMISSION_PROFILE'. Valid: core | minimum-dynamic | minimum-static${RESET}"
    exit 1
    ;;
esac

if [[ "$PERMISSION_PROFILE" == "minimum-dynamic" && "$PLACEMENT_MODE" != "dynamic" ]] ||
   [[ "$PERMISSION_PROFILE" == "minimum-static" && "$PLACEMENT_MODE" != "static" ]]; then
  echo -e "${RED}ERROR: PERMISSION_PROFILE '$PERMISSION_PROFILE' conflicts with PLACEMENT_MODE '$PLACEMENT_MODE'.${RESET}"
  exit 1
fi

# Derive partition-specific ARN prefix
case "$PARTITION" in
  aws)         ARN_PREFIX="arn:aws"         ;;
  aws-us-gov)  ARN_PREFIX="arn:aws-us-gov"  ;;
  aws-iso)     ARN_PREFIX="arn:aws-iso"     ;;
  aws-iso-b)   ARN_PREFIX="arn:aws-iso-b"   ;;
  *)
    echo -e "${RED}ERROR: Unknown partition '$PARTITION'. Valid: aws | aws-us-gov | aws-iso | aws-iso-b${RESET}"
    exit 1
    ;;
esac

# ─── Pre-flight checks ───────────────────────────────────────────────────────
header "Pre-flight Checks"

# Require AWS CLI
if ! command -v aws &>/dev/null; then
  echo -e "${RED}ERROR: aws CLI not found. Install it first.${RESET}"; exit 1
fi
pass "aws CLI found: $(aws --version 2>&1 | head -1)"

# Require jq
if ! command -v jq &>/dev/null; then
  echo -e "${RED}ERROR: jq not found. Install it first.${RESET}"; exit 1
fi
pass "jq found"

# Resolve account ID if not provided
if [[ -z "$AWS_ACCOUNT" ]]; then
  AWS_ACCOUNT=$(aws sts get-caller-identity --query Account --output text 2>/dev/null || true)
  if [[ -z "$AWS_ACCOUNT" ]]; then
    fail "Cannot resolve AWS Account ID. Check credentials / AWS_PROFILE." \
      "Run 'aws sts get-caller-identity --profile $AWS_PROFILE'. If it fails, correct AWS_PROFILE, authenticate the profile, and verify its configured region."
    exit 1
  fi
fi
info "AWS Account : $AWS_ACCOUNT"
info "Partition   : $PARTITION  (ARN prefix: $ARN_PREFIX)"
info "Cluster     : ${CLUSTER_NAME:-<not set — EKS checks will be skipped>}"
info "Placement   : $PLACEMENT_MODE"
info "Permissions : $PERMISSION_PROFILE"
info "Auth mode   : $AUTH_MODE"

# ─── Helper: check a single IAM action via simulate-principal-policy ─────────
# Usage: check_permission <principal-arn> <action> <resource> [remediation]
check_permission() {
  local principal="$1" action="$2" resource="$3"
  local remediation="${4:-Allow '$action' on '$resource' for $principal. Also check permission boundaries and organization SCPs for an explicit deny.}"
  local result
  result=$(aws iam simulate-principal-policy \
    --policy-source-arn "$principal" \
    --action-names "$action" \
    --resource-arns "$resource" \
    --query 'EvaluationResults[0].EvalDecision' \
    --output text 2>/dev/null || echo "error")
  if [[ "$result" == "allowed" ]]; then
    pass "$action  →  allowed"
  elif [[ "$result" == "error" ]]; then
    fail "Unable to simulate $action for $principal" \
      "Grant the current caller 'iam:SimulatePrincipalPolicy', verify the role and resource ARN, and retry the simulation with AWS CLI --debug to reveal the underlying API error."
  else
    fail "$action  →  $result  (resource: $resource)" "$remediation"
  fi
}

# ─── Helper: check a batch of actions for a given principal ──────────────────
check_permissions_batch() {
  local principal="$1"; shift
  local resource="$1"; shift
  local actions=("$@")
  local results
  if ! results=$(aws iam simulate-principal-policy \
    --policy-source-arn "$principal" \
    --action-names "${actions[@]}" \
    --resource-arns "$resource" \
    --query 'EvaluationResults[].{Action:EvalActionName,Decision:EvalDecision}' \
    --output json 2>/dev/null); then
    fail "Unable to simulate permissions for $principal" \
      "Grant the current caller 'iam:SimulatePrincipalPolicy', verify the role exists, and retry the AWS CLI command with --debug if the error persists."
    return
  fi
  while IFS= read -r row; do
    local action decision
    action=$(echo "$row" | jq -r '.Action')
    decision=$(echo "$row" | jq -r '.Decision')
    if [[ "$decision" == "allowed" ]]; then
      pass "$action"
    else
      fail "$action  →  $decision  (resource: $resource)" \
        "Allow '$action' on '$resource' for $principal. Also inspect permission boundaries and organization SCPs."
    fi
  done < <(echo "$results" | jq -c '.[]')
}

# ─── Resolve caller identity ─────────────────────────────────────────────────
header "Caller Identity (Current Credentials)"
CALLER_ARN=$(aws sts get-caller-identity --query Arn --output text)
CALLER_TYPE=$(aws sts get-caller-identity --query '[UserId,Arn]' --output text)
info "Caller ARN  : $CALLER_ARN"

# ─── Section 1: Credential Baseline ──────────────────────────────────────────
header "Section 1: Credential Baseline Validation"

info "Verifying sts:GetCallerIdentity..."
if aws sts get-caller-identity &>/dev/null; then
  pass "sts:GetCallerIdentity succeeded"
else
  fail "sts:GetCallerIdentity failed — credentials may be invalid" \
    "Authenticate AWS profile '$AWS_PROFILE', then run 'aws sts get-caller-identity --profile $AWS_PROFILE' to confirm the session is valid."
fi

# ─── Section 2: Minimum EKS Permissions (Deployer / Cloud Account role) ──────
header "Section 2: EKS Deployment Permissions (${PERMISSION_PROFILE}; ${PLACEMENT_MODE} placement)"

# Resolve the principal whose deployment permissions should be simulated.
DEPLOYER_ROLE_ARN="${ARN_PREFIX}:iam::${AWS_ACCOUNT}:role/${DEPLOYER_ROLE_NAME}"
if [[ "$AUTH_MODE" == "secret" ]]; then
  VALIDATION_PRINCIPAL_ARN=""
  if [[ "$CALLER_ARN" == ${ARN_PREFIX}:iam::*:user/* ]]; then
    VALIDATION_PRINCIPAL_ARN="$CALLER_ARN"
  else
    fail "Secret mode requires long-lived credentials for an IAM user, but the caller is: $CALLER_ARN" \
      "Configure AWS_PROFILE with the same access key and secret key stored for Palette. If this profile assumes a role or uses temporary credentials, select AUTH_MODE='sts' instead. Root credentials are not supported."
  fi
else
  VALIDATION_PRINCIPAL_ARN="$DEPLOYER_ROLE_ARN"
  if aws iam get-role --role-name "$DEPLOYER_ROLE_NAME" &>/dev/null; then
    pass "IAM role '$DEPLOYER_ROLE_NAME' exists"
  else
    fail "IAM role '$DEPLOYER_ROLE_NAME' not found — create it before deploying Palette VerteX" \
      "Confirm DEPLOYER_ROLE_NAME and AWS_ACCOUNT in the config. If correct, create the role with the required Palette permission and trust policies."
  fi
fi
info "Permission principal: ${VALIDATION_PRINCIPAL_ARN:-<unresolved>}"

# 2a. EC2 permissions — common to both dynamic and static
EC2_COMMON_ACTIONS=(
  "ec2:DescribeInstances"
  "ec2:DescribeRegions"
  "ec2:DescribeAvailabilityZones"
  "ec2:DescribeVpcs"
  "ec2:DescribeSubnets"
  "ec2:DescribeRouteTables"
  "ec2:DescribeSecurityGroups"
  "ec2:DescribeNatGateways"
  "ec2:DescribeNetworkInterfaces"
  "ec2:DescribeKeyPairs"
  "ec2:CreateTags"
  "ec2:CreateSecurityGroup"
  "ec2:DeleteSecurityGroup"
  "ec2:AuthorizeSecurityGroupIngress"
)

info "Checking common EC2 permissions..."
if [[ -n "$VALIDATION_PRINCIPAL_ARN" ]]; then
  check_permissions_batch "$VALIDATION_PRINCIPAL_ARN" "*" "${EC2_COMMON_ACTIONS[@]}"
fi

# 2b. Dynamic-placement-only EC2 permissions
if [[ "$PLACEMENT_MODE" == "dynamic" ]]; then
  EC2_DYNAMIC_ACTIONS=(
    "ec2:CreateVpc"
    "ec2:DeleteVpc"
    "ec2:ModifyVpcAttribute"
    "ec2:DescribeVpcAttribute"
    "ec2:DescribeVpcEndpoints"
    "ec2:CreateSubnet"
    "ec2:DeleteSubnet"
    "ec2:ModifySubnetAttribute"
    "ec2:CreateRouteTable"
    "ec2:DeleteRouteTable"
    "ec2:AssociateRouteTable"
    "ec2:DisassociateRouteTable"
    "ec2:CreateRoute"
    "ec2:CreateInternetGateway"
    "ec2:DeleteInternetGateway"
    "ec2:AttachInternetGateway"
    "ec2:DetachInternetGateway"
    "ec2:DescribeInternetGateways"
    "ec2:CreateNatGateway"
    "ec2:DeleteNatGateway"
    "ec2:AllocateAddress"
    "ec2:ReleaseAddress"
    "ec2:DescribeAddresses"
    "ec2:DeleteNetworkInterface"
  )
  info "Checking dynamic-placement EC2 permissions..."
  if [[ -n "$VALIDATION_PRINCIPAL_ARN" ]]; then
    check_permissions_batch "$VALIDATION_PRINCIPAL_ARN" "*" "${EC2_DYNAMIC_ACTIONS[@]}"
  fi
fi

# 2c. Static-placement-only EC2 permissions
if [[ "$PLACEMENT_MODE" == "static" ]]; then
  EC2_STATIC_ACTIONS=(
    "ec2:DeleteTags"
    "ec2:DescribeTags"
  )
  info "Checking static-placement EC2 permissions..."
  if [[ -n "$VALIDATION_PRINCIPAL_ARN" ]]; then
    check_permissions_batch "$VALIDATION_PRINCIPAL_ARN" "*" "${EC2_STATIC_ACTIONS[@]}"
  fi
fi

# 2d. EKS core permissions
EKS_CORE_ACTIONS=(
  "eks:CreateCluster"
  "eks:DeleteCluster"
  "eks:DescribeCluster"
  "eks:CreateNodegroup"
  "eks:DeleteNodegroup"
  "eks:DescribeNodegroup"
  "eks:TagResource"
  "eks:ListAddons"
)
info "Checking core EKS permissions..."
if [[ -n "$VALIDATION_PRINCIPAL_ARN" ]]; then
  check_permissions_batch "$VALIDATION_PRINCIPAL_ARN" "*" "${EKS_CORE_ACTIONS[@]}"
fi

# 2e. Palette-role EKS add-on permissions.
# Spectro's minimum Pod Identity supplement grants only DescribeAddonVersions,
# CreateAddon, and UpdateAddon to the Palette role. DescribeAddon and
# DeleteAddon are part of the core/controller policy rather than the minimum
# Palette-role supplement.
if [[ "$AUTH_MODE" == "pod-identity" ]]; then
  if [[ "$PERMISSION_PROFILE" == "core" ]]; then
    EKS_ADDON_ACTIONS=(
      "eks:DescribeAddonVersions"
      "eks:DescribeAddon"
      "eks:CreateAddon"
      "eks:DeleteAddon"
      "eks:UpdateAddon"
    )
  else
    EKS_ADDON_ACTIONS=(
      "eks:DescribeAddonVersions"
      "eks:CreateAddon"
      "eks:UpdateAddon"
    )
  fi
  info "Checking $PERMISSION_PROFILE Palette-role EKS add-on permissions..."
  check_permissions_batch "$VALIDATION_PRINCIPAL_ARN" "*" "${EKS_ADDON_ACTIONS[@]}"
else
  info "Skipping Pod Identity addon permissions for auth mode '$AUTH_MODE'"
fi

# 2f. OIDC provider permissions
info "Checking OIDC provider permissions..."
OIDC_WILDCARD="${ARN_PREFIX}:iam::${AWS_ACCOUNT}:oidc-provider/*"
if [[ -n "$VALIDATION_PRINCIPAL_ARN" ]]; then
  check_permission "$VALIDATION_PRINCIPAL_ARN" "iam:ListOpenIDConnectProviders" "*"
  check_permission "$VALIDATION_PRINCIPAL_ARN" "iam:CreateOpenIDConnectProvider" "$OIDC_WILDCARD"
  check_permission "$VALIDATION_PRINCIPAL_ARN" "iam:GetOpenIDConnectProvider"    "$OIDC_WILDCARD"
  check_permission "$VALIDATION_PRINCIPAL_ARN" "iam:DeleteOpenIDConnectProvider" "$OIDC_WILDCARD"
  check_permission "$VALIDATION_PRINCIPAL_ARN" "iam:TagOpenIDConnectProvider"    "$OIDC_WILDCARD"
fi

# 2g. IAM role permissions (scoped to CAPA naming pattern)
CAPA_ROLE_PATTERN="${ARN_PREFIX}:iam::${AWS_ACCOUNT}:role/*.cluster-api-provider-aws.sigs.k8s.io"
info "Checking IAM role permissions (CAPA naming pattern)..."
if [[ -n "$VALIDATION_PRINCIPAL_ARN" ]]; then
  if [[ "$VALIDATION_PRINCIPAL_ARN" == "$DEPLOYER_ROLE_ARN" ]]; then
    CAPA_PASSROLE_FIX="Render and attach the reusable CAPA policy to '$DEPLOYER_ROLE_NAME': aws iam put-role-policy --role-name '$DEPLOYER_ROLE_NAME' --policy-name 'PaletteCAPAPassRole' --policy-document \"\$(bash '${SCRIPT_DIR}/render-capa-policy.sh')\" --profile '$AWS_PROFILE'."
  else
    CAPA_PASSROLE_FIX="Allow iam:PassRole on '$CAPA_ROLE_PATTERN' for '$VALIDATION_PRINCIPAL_ARN'. Render policies/capa-passrole-policy.template.json with render-capa-policy.sh, then attach it to the IAM user represented by the static credentials."
  fi
  check_permission "$VALIDATION_PRINCIPAL_ARN" "iam:GetRole"                 "$CAPA_ROLE_PATTERN"
  check_permission "$VALIDATION_PRINCIPAL_ARN" "iam:PassRole" "$CAPA_ROLE_PATTERN" "$CAPA_PASSROLE_FIX"
  check_permission "$VALIDATION_PRINCIPAL_ARN" "iam:ListAttachedRolePolicies" "$CAPA_ROLE_PATTERN"
fi

# 2h. Autoscaling permissions
info "Checking autoscaling permissions..."
if [[ -n "$VALIDATION_PRINCIPAL_ARN" ]]; then
  check_permission "$VALIDATION_PRINCIPAL_ARN" "autoscaling:DescribeAutoScalingGroups" "*"
fi

# ─── Section 3: Pod Identity — Role Existence & Trust Policy Validation ───────
if [[ "$AUTH_MODE" == "pod-identity" ]]; then
  header "Section 3: Pod Identity Role Validation"

validate_pod_identity_trust() {
  local role_name="$1"
  local role_arn="${ARN_PREFIX}:iam::${AWS_ACCOUNT}:role/${role_name}"

  info "Checking role: $role_name ($role_arn)"

  # 3a. Role must exist
  local trust_doc
  trust_doc=$(aws iam get-role --role-name "$role_name" \
    --query 'Role.AssumeRolePolicyDocument' --output json 2>/dev/null || echo "null")

  if [[ "$trust_doc" == "null" ]]; then
    fail "Role '$role_name' not found" \
      "Confirm the configured role name and AWS account. If absent, create '$role_name' and add an EKS Pod Identity trust statement like policies/trust-policy.json."
    return
  fi
  pass "Role '$role_name' exists"

  # 3b. Trust policy must allow pods.eks.amazonaws.com to sts:AssumeRole + sts:TagSession
  local has_pod_principal has_assume has_tag
  has_pod_principal=$(echo "$trust_doc" | jq -r '
    .Statement[]
    | select(.Principal.Service? == "pods.eks.amazonaws.com")
    | .Effect' 2>/dev/null | head -1)

  has_assume=$(echo "$trust_doc" | jq -r '
    .Statement[]
    | select(.Principal.Service? == "pods.eks.amazonaws.com")
    | .Action
    | if type == "array" then .[] else . end
    | select(. == "sts:AssumeRole")' 2>/dev/null | head -1)

  has_tag=$(echo "$trust_doc" | jq -r '
    .Statement[]
    | select(.Principal.Service? == "pods.eks.amazonaws.com")
    | .Action
    | if type == "array" then .[] else . end
    | select(. == "sts:TagSession")' 2>/dev/null | head -1)

  if [[ "$has_pod_principal" == "Allow" ]]; then
    pass "Trust policy allows pods.eks.amazonaws.com"
  else
    fail "Trust policy does NOT allow pods.eks.amazonaws.com — Pod Identity will not work" \
      "Update the trust policy for '$role_name' to include an Allow statement with Service 'pods.eks.amazonaws.com'; use policies/trust-policy.json as a reference without replacing unrelated trust statements."
  fi

  if [[ -n "$has_assume" ]]; then
    pass "Trust policy includes sts:AssumeRole for EKS Pod Identity"
  else
    fail "Trust policy missing sts:AssumeRole for pods.eks.amazonaws.com" \
      "Add 'sts:AssumeRole' to the actions allowed for the pods.eks.amazonaws.com principal in the '$role_name' trust policy."
  fi

  if [[ -n "$has_tag" ]]; then
    pass "Trust policy includes sts:TagSession for EKS Pod Identity"
  else
    fail "Trust policy missing sts:TagSession for pods.eks.amazonaws.com" \
      "Add 'sts:TagSession' to the actions allowed for the pods.eks.amazonaws.com principal in the '$role_name' trust policy."
  fi
}

# Validate all three Pod Identity roles
validate_pod_identity_trust "$DEPLOYER_ROLE_NAME"
validate_pod_identity_trust "$HUBBLE_ROLE_NAME"
validate_pod_identity_trust "$IDENTITY_ROLE_NAME"

# ─── Section 4: Pod Identity — Permission Policy Validation ───────────────────
header "Section 4: Pod Identity Permission Policy Checks"

# 4a. Palette/deployer role — must have Pod Identity management permissions.
# Add-on permissions were checked once, with the selected profile, in Section 2.
info "Checking '$DEPLOYER_ROLE_NAME' Pod Identity management permissions..."
DEPLOYER_ROLE_ARN="${ARN_PREFIX}:iam::${AWS_ACCOUNT}:role/${DEPLOYER_ROLE_NAME}"
POD_IDENTITY_MGMT_ACTIONS=(
  "eks:ListPodIdentityAssociations"
  "eks:CreatePodIdentityAssociation"
  "eks:DeletePodIdentityAssociation"
)
check_permissions_batch "$DEPLOYER_ROLE_ARN" "*" "${POD_IDENTITY_MGMT_ACTIONS[@]}"
check_permission "$DEPLOYER_ROLE_ARN" "iam:PassRole" "*" \
  "Attach the bundled policy to '$DEPLOYER_ROLE_NAME': aws iam put-role-policy --role-name '$DEPLOYER_ROLE_NAME' --policy-name 'PalettePodIdentityManagement' --policy-document 'file://${SCRIPT_DIR}/policies/deployerv2-passrole.json' --profile '$AWS_PROFILE'. If it remains denied, inspect the role's permissions boundary and organization SCPs."

# 4b. spectro-hubble — must have IAM validation, EC2 describe, EKS describe, KMS read
info "Checking spectro-hubble-role permissions..."
HUBBLE_ROLE_ARN="${ARN_PREFIX}:iam::${AWS_ACCOUNT}:role/${HUBBLE_ROLE_NAME}"

HUBBLE_IAM_ACTIONS=(
  "iam:GetRole"
  "iam:ListAttachedRolePolicies"
  "iam:ListRolePolicies"
  "iam:GetRolePolicy"
  "iam:GetPolicy"
  "iam:GetPolicyVersion"
)
info "  IAM validation permissions..."
check_permissions_batch "$HUBBLE_ROLE_ARN" "*" "${HUBBLE_IAM_ACTIONS[@]}"

HUBBLE_EC2_ACTIONS=(
  "ec2:DescribeRegions"
  "ec2:DescribeAvailabilityZones"
  "ec2:DescribeVpcs"
  "ec2:DescribeSubnets"
  "ec2:DescribeRouteTables"
  "ec2:DescribeKeyPairs"
)
info "  EC2 describe permissions..."
check_permissions_batch "$HUBBLE_ROLE_ARN" "*" "${HUBBLE_EC2_ACTIONS[@]}"

HUBBLE_EKS_ACTIONS=(
  "eks:DescribeCluster"
  "eks:ListClusters"
  "eks:DescribeNodegroup"
  "eks:ListNodegroups"
  "eks:DescribeAddon"
  "eks:ListAddons"
)
info "  EKS describe permissions..."
check_permissions_batch "$HUBBLE_ROLE_ARN" "*" "${HUBBLE_EKS_ACTIONS[@]}"

HUBBLE_KMS_ACTIONS=(
  "kms:ListKeys"
  "kms:ListAliases"
  "kms:DescribeKey"
  "kms:GetKeyPolicy"
  "kms:GetKeyRotationStatus"
)
info "  KMS read permissions..."
check_permissions_batch "$HUBBLE_ROLE_ARN" "*" "${HUBBLE_KMS_ACTIONS[@]}"

# 4c. palette-identity — must have Pod Identity management, EC2 describe, and IAM PassRole
info "Checking palette-identity-role permissions..."
IDENTITY_ROLE_ARN="${ARN_PREFIX}:iam::${AWS_ACCOUNT}:role/${IDENTITY_ROLE_NAME}"

IDENTITY_POD_ACTIONS=(
  "eks:ListPodIdentityAssociations"
  "eks:CreatePodIdentityAssociation"
  "eks:DeletePodIdentityAssociation"
)
info "  Pod Identity management permissions..."
check_permissions_batch "$IDENTITY_ROLE_ARN" "*" "${IDENTITY_POD_ACTIONS[@]}"

info "  EC2 describe permissions..."
check_permission "$IDENTITY_ROLE_ARN" "ec2:DescribeInstances" "*"

info "  IAM GetRole + PassRole scoped to '$DEPLOYER_ROLE_NAME'..."
check_permission "$IDENTITY_ROLE_ARN" "iam:GetRole"  "$DEPLOYER_ROLE_ARN"
check_permission "$IDENTITY_ROLE_ARN" "iam:PassRole" "$DEPLOYER_ROLE_ARN"

else
  header "Sections 3–4: Pod Identity Validation"
  info "Skipped for auth mode '$AUTH_MODE'"
fi

# ─── Section 5: STS Validation ────────────────────────────────────────────────
header "Section 5: STS Validation"

if [[ "$AUTH_MODE" == "sts" ]]; then
  info "Attempting sts:AssumeRole with session tags into $DEPLOYER_ROLE_NAME..."
  ASSUMED=$(aws sts assume-role \
    --role-arn "$DEPLOYER_ROLE_ARN" \
    --role-session-name "palette-vertex-iam-validation-$$" \
    --duration-seconds 900 \
    --tags Key=PaletteValidation,Value=true \
    --query 'Credentials.AccessKeyId' \
    --output text 2>/dev/null || echo "FAILED")

  if [[ "$ASSUMED" != "FAILED" && -n "$ASSUMED" ]]; then
    pass "sts:AssumeRole with sts:TagSession into '$DEPLOYER_ROLE_NAME' succeeded (session key: ${ASSUMED:0:8}...)"
  else
    fail "sts:AssumeRole with session tags into '$DEPLOYER_ROLE_NAME' failed" \
      "Allow the current caller to use sts:AssumeRole and sts:TagSession on '$DEPLOYER_ROLE_ARN', and ensure the role trust policy allows the caller and both actions. Inspect it with: aws iam get-role --role-name '$DEPLOYER_ROLE_NAME'"
  fi
else
  info "Skipped for auth mode '$AUTH_MODE'; direct role assumption is only required for STS authentication"
fi

# ─── Section 6: EKS Cluster Checks (if CLUSTER_NAME is set) ──────────────────
header "Section 6: EKS Cluster Checks"

if [[ -z "$CLUSTER_NAME" ]]; then
  warn "CLUSTER_NAME not set — skipping live EKS cluster checks"
else
  # 6a. Cluster exists and is ACTIVE
  info "Checking EKS cluster '$CLUSTER_NAME'..."
  CLUSTER_STATUS=$(aws eks describe-cluster \
    --name "$CLUSTER_NAME" \
    --query 'cluster.status' \
    --output text 2>/dev/null || echo "NOT_FOUND")

  if [[ "$CLUSTER_STATUS" == "ACTIVE" ]]; then
    pass "Cluster '$CLUSTER_NAME' is ACTIVE"
  elif [[ "$CLUSTER_STATUS" == "NOT_FOUND" ]]; then
    fail "Cluster '$CLUSTER_NAME' not found" \
      "Confirm CLUSTER_NAME, AWS_PROFILE, and the profile's region. Test with: aws eks describe-cluster --name '$CLUSTER_NAME' --profile '$AWS_PROFILE'"
  else
    warn "Cluster '$CLUSTER_NAME' status: $CLUSTER_STATUS"
  fi

  if [[ "$AUTH_MODE" == "pod-identity" ]]; then
    # 6b. Kubernetes version >= 1.24 (required for Pod Identity)
    K8S_VERSION=$(aws eks describe-cluster \
    --name "$CLUSTER_NAME" \
    --query 'cluster.version' \
    --output text 2>/dev/null || echo "0.0")
  MAJOR=$(echo "$K8S_VERSION" | cut -d. -f1)
  MINOR=$(echo "$K8S_VERSION" | cut -d. -f2)

  if [[ "$MAJOR" -ge 1 && "$MINOR" -ge 24 ]]; then
    pass "Kubernetes version $K8S_VERSION >= 1.24 (Pod Identity supported)"
  else
    fail "Kubernetes version $K8S_VERSION < 1.24 — EKS Pod Identity requires 1.24+" \
      "Upgrade the EKS control plane and node groups to a supported Kubernetes version before enabling Pod Identity."
  fi

  # 6c. Pod Identity agent addon is installed
  info "Checking eks-pod-identity-agent addon..."
  ADDON_STATUS=$(aws eks describe-addon \
    --cluster-name "$CLUSTER_NAME" \
    --addon-name eks-pod-identity-agent \
    --query 'addon.status' \
    --output text 2>/dev/null || echo "NOT_FOUND")

  if [[ "$ADDON_STATUS" == "ACTIVE" ]]; then
    pass "eks-pod-identity-agent addon is ACTIVE"
  elif [[ "$ADDON_STATUS" == "NOT_FOUND" ]]; then
    fail "eks-pod-identity-agent addon not installed" \
      "Install it with: aws eks create-addon --cluster-name '$CLUSTER_NAME' --addon-name eks-pod-identity-agent --profile '$AWS_PROFILE'"
  else
    warn "eks-pod-identity-agent addon status: $ADDON_STATUS"
  fi

  # 6d. Pod Identity associations exist for required service accounts
  info "Checking Pod Identity associations on cluster '$CLUSTER_NAME'..."
  ASSOCIATIONS=$(aws eks list-pod-identity-associations \
    --cluster-name "$CLUSTER_NAME" \
    --query 'associations[].{NS:namespace,SA:serviceAccount,Role:roleArn}' \
    --output json 2>/dev/null || echo "[]")

  check_association() {
    local ns="$1" sa="$2" label="$3" expected_role_arn="$4"
    local found
    found=$(echo "$ASSOCIATIONS" | jq -r \
      --arg ns "$ns" --arg sa "$sa" \
      '.[] | select(.NS==$ns and .SA==$sa) | .Role' 2>/dev/null | head -1)
    if [[ -n "$found" ]]; then
      pass "Pod Identity association found: $label ($ns/$sa → $found)"
    else
      fail "Pod Identity association MISSING: $label ($ns/$sa)" \
        "Create it with: aws eks create-pod-identity-association --cluster-name '$CLUSTER_NAME' --namespace '$ns' --service-account '$sa' --role-arn '$expected_role_arn' --profile '$AWS_PROFILE'"
    fi
  }

    check_association "hubble-system" "spectro-hubble" "spectro-hubble" "$HUBBLE_ROLE_ARN"
    check_association "palette-identity" "palette-identity" "palette-identity" "$IDENTITY_ROLE_ARN"
  else
    info "Skipping Pod Identity version, addon, and association checks for auth mode '$AUTH_MODE'"
  fi

  # 6e. OIDC provider is configured for the cluster
  info "Checking OIDC provider for cluster '$CLUSTER_NAME'..."
  OIDC_ISSUER=$(aws eks describe-cluster \
    --name "$CLUSTER_NAME" \
    --query 'cluster.identity.oidc.issuer' \
    --output text 2>/dev/null || echo "None")

  if [[ "$OIDC_ISSUER" != "None" && -n "$OIDC_ISSUER" ]]; then
    pass "OIDC issuer configured: $OIDC_ISSUER"

    # Check the OIDC provider is registered in IAM
    OIDC_ID=$(echo "$OIDC_ISSUER" | awk -F'/' '{print $NF}')
    OIDC_ARN="${ARN_PREFIX}:iam::${AWS_ACCOUNT}:oidc-provider/oidc.eks.$(aws configure get region 2>/dev/null || echo "us-east-1").amazonaws.com/id/${OIDC_ID}"
    if aws iam get-open-id-connect-provider --open-id-connect-provider-arn "$OIDC_ARN" &>/dev/null; then
      pass "OIDC provider registered in IAM: $OIDC_ARN"
    else
      warn "OIDC provider NOT registered in IAM — Palette OIDC auth may fail"
      warn "Expected ARN: $OIDC_ARN"
    fi
  else
    fail "No OIDC issuer found on cluster '$CLUSTER_NAME'" \
      "Verify that '$CLUSTER_NAME' is the intended EKS cluster and that the caller can run eks:DescribeCluster. Re-run 'aws eks describe-cluster --name $CLUSTER_NAME --query cluster.identity.oidc'."
  fi
fi

# ─── Section 7: Partition-Specific ARN Validation ─────────────────────────────
header "Section 7: Partition-Specific ARN Validation"

info "Validating ARN prefix consistency for partition: $PARTITION"

# 7a. Confirm all role ARNs use the correct partition prefix
validate_arn_partition() {
  local role_name="$1"
  local role_arn
  role_arn=$(aws iam get-role --role-name "$role_name" \
    --query 'Role.Arn' --output text 2>/dev/null || echo "NOT_FOUND")

  if [[ "$role_arn" == "NOT_FOUND" ]]; then
    warn "Role '$role_name' not found — skipping ARN partition check"
    return
  fi

  if [[ "$role_arn" == ${ARN_PREFIX}:* ]]; then
    pass "Role '$role_name' ARN uses correct partition prefix '$ARN_PREFIX': $role_arn"
  else
    fail "Role '$role_name' ARN uses WRONG partition prefix. Expected '$ARN_PREFIX', got: $role_arn" \
      "Correct PARTITION and AWS_PROFILE so they target the same AWS partition. IAM role ARNs cannot change partition; use or create the role in the intended partition."
  fi
}

case "$AUTH_MODE" in
  secret)
    if [[ -n "$VALIDATION_PRINCIPAL_ARN" ]]; then
      if [[ "$VALIDATION_PRINCIPAL_ARN" == ${ARN_PREFIX}:* ]]; then
        pass "Static credential principal uses correct partition prefix '$ARN_PREFIX': $VALIDATION_PRINCIPAL_ARN"
      else
        fail "Static credential principal uses the wrong partition: $VALIDATION_PRINCIPAL_ARN" \
          "Correct PARTITION and AWS_PROFILE so the configured static credentials belong to the intended AWS partition."
      fi
    fi
    ;;
  sts)
    validate_arn_partition "$DEPLOYER_ROLE_NAME"
    ;;
  pod-identity)
    validate_arn_partition "$DEPLOYER_ROLE_NAME"
    validate_arn_partition "$HUBBLE_ROLE_NAME"
    validate_arn_partition "$IDENTITY_ROLE_NAME"
    ;;
esac

# 7b. GovCloud-specific checks
if [[ "$PARTITION" == "aws-us-gov" ]]; then
  info "GovCloud partition detected — running additional checks..."

  # Confirm the AWS region is a GovCloud region
  CURRENT_REGION=$(aws configure get region 2>/dev/null || echo "unknown")
  if [[ "$CURRENT_REGION" == us-gov-* ]]; then
    pass "AWS region '$CURRENT_REGION' is a valid GovCloud region"
  else
    fail "AWS region '$CURRENT_REGION' does not appear to be a GovCloud region (expected us-gov-east-1 or us-gov-west-1)" \
      "Set a GovCloud region on profile '$AWS_PROFILE', for example: aws configure set region us-gov-west-1 --profile '$AWS_PROFILE'"
  fi

  # Warn that Palette SaaS does not support GovCloud — VerteX is required
  warn "GovCloud partition is ONLY supported by Palette VerteX, not Palette SaaS."
  warn "Ensure you are deploying a self-hosted VerteX instance, not a Palette SaaS-connected cluster."

  # Confirm OIDC provider ARN uses aws-us-gov partition
  if [[ -n "${CLUSTER_NAME:-}" ]]; then
    OIDC_ISSUER_GOV=$(aws eks describe-cluster \
      --name "$CLUSTER_NAME" \
      --query 'cluster.identity.oidc.issuer' \
      --output text 2>/dev/null || echo "None")

    if [[ "$OIDC_ISSUER_GOV" != "None" && -n "$OIDC_ISSUER_GOV" ]]; then
      OIDC_ID_GOV=$(echo "$OIDC_ISSUER_GOV" | awk -F'/' '{print $NF}')
      GOV_OIDC_ARN="arn:aws-us-gov:iam::${AWS_ACCOUNT}:oidc-provider/oidc.eks.${CURRENT_REGION}.amazonaws.com/id/${OIDC_ID_GOV}"
      if aws iam get-open-id-connect-provider --open-id-connect-provider-arn "$GOV_OIDC_ARN" &>/dev/null; then
        pass "GovCloud OIDC provider registered in IAM: $GOV_OIDC_ARN"
      else
        fail "GovCloud OIDC provider NOT found in IAM. Expected: $GOV_OIDC_ARN" \
          "Verify the account and region used to build the ARN. If this deployment requires IAM OIDC, register the cluster's issuer as an IAM OIDC provider in the GovCloud account."
      fi
    fi
  fi
fi

# ─── Section 8: IAM Role Naming Convention Validation ─────────────────────────
header "Section 8: IAM Role Naming Convention (CAPA Pattern)"

# CAPA roles must follow *.cluster-api-provider-aws.sigs.k8s.io naming
CAPA_ROLES=(
  "controllers.cluster-api-provider-aws.sigs.k8s.io"
  "control-plane.cluster-api-provider-aws.sigs.k8s.io"
  "nodes.cluster-api-provider-aws.sigs.k8s.io"
  "eks-controlplane.cluster-api-provider-aws.sigs.k8s.io"
  "eks-nodegroup.cluster-api-provider-aws.sigs.k8s.io"
  "eks-fargate.cluster-api-provider-aws.sigs.k8s.io"
)

info "Checking for pre-created CAPA CloudFormation stack roles..."
MISSING_CAPA_ROLES=0
for capa_role in "${CAPA_ROLES[@]}"; do
  if aws iam get-role --role-name "$capa_role" &>/dev/null; then
    pass "CAPA role exists: $capa_role"
  else
    warn "CAPA role NOT found: $capa_role"
    warn "  → If using 'Manage CloudFormation Stack Manually' mode, pre-create this role."
    warn "  → If Palette manages the CloudFormation stack, this will be created automatically."
    MISSING_CAPA_ROLES=$((MISSING_CAPA_ROLES+1))
  fi
done

if [[ "$MISSING_CAPA_ROLES" -gt 0 ]]; then
  warn "$MISSING_CAPA_ROLES CAPA role(s) missing. If CFS skip mode is enabled, create the stack manually:"
  warn "  aws cloudformation create-stack \\"
  warn "    --stack-name cluster-api-provider-aws-sigs-k8s-io \\"
  warn "    --template-body file://palette-cloudformation-input.yaml \\"
  warn "    --capabilities CAPABILITY_NAMED_IAM \\"
  warn "    --region \$AWS_REGION"
fi

# ─── Section 9: Cross-Account STS Validation (optional) ───────────────────────
header "Section 9: Cross-Account STS Validation"

if [[ "$AUTH_MODE" == "secret" ]]; then
  info "Skipped for secret authentication; static credentials do not assume a target role"
elif [[ "$AUTH_MODE" == "sts" && -z "$TARGET_ACCOUNT_ID" ]]; then
  warn "TARGET_ACCOUNT_ID not set — skipping cross-account STS checks"
  warn "  Set TARGET_ACCOUNT_ID=<account-id> to validate cross-account role assumption"
elif [[ "$AUTH_MODE" == "sts" ]]; then
  TARGET_DEPLOYER_ARN="${ARN_PREFIX}:iam::${TARGET_ACCOUNT_ID}:role/${DEPLOYER_ROLE_NAME}"
  info "Attempting cross-account sts:AssumeRole with session tags into: $TARGET_DEPLOYER_ARN"
  CROSS_ASSUMED=$(aws sts assume-role \
    --role-arn "$TARGET_DEPLOYER_ARN" \
    --role-session-name "palette-vertex-cross-account-validation-$$" \
    --duration-seconds 900 \
    --tags Key=PaletteValidation,Value=true \
    --query 'Credentials.AccessKeyId' \
    --output text 2>/dev/null || echo "FAILED")

  if [[ "$CROSS_ASSUMED" != "FAILED" && -n "$CROSS_ASSUMED" ]]; then
    pass "Cross-account sts:AssumeRole with sts:TagSession into '$TARGET_DEPLOYER_ARN' succeeded"
  else
    fail "Cross-account sts:AssumeRole with session tags into '$TARGET_DEPLOYER_ARN' failed" \
      "Allow the current caller to use sts:AssumeRole and sts:TagSession on '$TARGET_DEPLOYER_ARN', and update the target role trust policy to allow the caller and both actions."
  fi
elif [[ -z "$TARGET_ACCOUNT_ID" ]]; then
  warn "TARGET_ACCOUNT_ID not set — skipping Pod Identity cross-account checks"
  warn "  Set TARGET_ACCOUNT_ID=<account-id> to validate cross-account role assumption"
else
  info "Validating Pod Identity cross-account role assumption (management → target account: $TARGET_ACCOUNT_ID)..."

  TARGET_DEPLOYER_ARN="${ARN_PREFIX}:iam::${TARGET_ACCOUNT_ID}:role/${DEPLOYER_ROLE_NAME}"
  TARGET_HUBBLE_ARN="${ARN_PREFIX}:iam::${TARGET_ACCOUNT_ID}:role/${HUBBLE_ROLE_NAME}"

  info "Simulating palette-identity permissions on target deployer role..."
  check_permission "$IDENTITY_ROLE_ARN" "sts:AssumeRole" "$TARGET_DEPLOYER_ARN" \
    "Allow '$IDENTITY_ROLE_ARN' to assume '$TARGET_DEPLOYER_ARN'; in the target account, add the identity role to the target role trust policy."
  check_permission "$IDENTITY_ROLE_ARN" "sts:TagSession" "$TARGET_DEPLOYER_ARN" \
    "Allow '$IDENTITY_ROLE_ARN' to tag sessions on '$TARGET_DEPLOYER_ARN', and permit sts:TagSession in the target role trust policy."

  info "Simulating spectro-hubble permissions on target Hubble role..."
  check_permission "$HUBBLE_ROLE_ARN" "sts:AssumeRole" "$TARGET_HUBBLE_ARN" \
    "Allow '$HUBBLE_ROLE_ARN' to assume '$TARGET_HUBBLE_ARN'; in the target account, trust the local Hubble role and configure the expected sts:ExternalId condition."
  check_permission "$HUBBLE_ROLE_ARN" "sts:TagSession" "$TARGET_HUBBLE_ARN" \
    "Allow '$HUBBLE_ROLE_ARN' to tag sessions on '$TARGET_HUBBLE_ARN', and permit sts:TagSession in the target role trust policy."
fi

# ─── Section 10: palette-global-config ConfigMap Check ────────────────────────
header "Section 10: palette-global-config ConfigMap (Pod Identity Prerequisite)"

if [[ "$AUTH_MODE" != "pod-identity" ]]; then
  info "Skipped for auth mode '$AUTH_MODE'"
elif [[ -z "$CLUSTER_NAME" ]]; then
  warn "CLUSTER_NAME not set — skipping ConfigMap check"
else
  info "Checking for palette-global-config ConfigMap in kube-system..."

  # Requires kubectl configured for the management cluster
  if ! command -v kubectl &>/dev/null; then
    warn "kubectl not found — skipping ConfigMap check"
  else
    CM_VALUE=$(kubectl get configmap palette-global-config \
      -n kube-system \
      -o jsonpath='{.data.managementClusterName}' 2>/dev/null || echo "NOT_FOUND")

    if [[ "$CM_VALUE" == "NOT_FOUND" || -z "$CM_VALUE" ]]; then
      fail "ConfigMap 'palette-global-config' in kube-system is missing or does not contain 'managementClusterName'" \
        "Create or update it with: kubectl create configmap palette-global-config -n kube-system --from-literal=managementClusterName='$CLUSTER_NAME' --dry-run=client -o yaml | kubectl apply -f -"
    else
      pass "ConfigMap 'palette-global-config' found with managementClusterName='$CM_VALUE'"
      if [[ "$CM_VALUE" == "$CLUSTER_NAME" ]]; then
        pass "managementClusterName matches CLUSTER_NAME ('$CLUSTER_NAME')"
      else
        warn "managementClusterName ('$CM_VALUE') does not match CLUSTER_NAME ('$CLUSTER_NAME') — verify this is intentional"
      fi
    fi
  fi
fi

# ─── Section 11: Pod Identity Environment Variable Verification ───────────────
header "Section 11: Pod Identity Environment Variable Verification"

if [[ "$AUTH_MODE" != "pod-identity" ]]; then
  info "Skipped for auth mode '$AUTH_MODE'"
elif ! command -v kubectl &>/dev/null; then
  warn "kubectl not found — skipping Pod Identity env var checks"
else
  check_pod_identity_env() {
    local namespace="$1" selector="$2" service_account="$3" label="$4"
    local pod_name pod_env env_var

    info "Checking $label pods for Pod Identity env vars..."
    if ! pod_name=$(kubectl get pods -n "$namespace" \
      -l "$selector" \
      -o jsonpath='{.items[0].metadata.name}' 2>/dev/null); then
      warn "Unable to query $label pods using the current kubectl context — skipping this runtime check"
    elif [[ -z "$pod_name" ]]; then
      warn "No pods found in $namespace with label '$selector' — skipping this runtime check"
    else
      info "Inspecting Pod Identity env vars on pod '$pod_name'..."
      if ! pod_env=$(kubectl get pod "$pod_name" -n "$namespace" \
        -o jsonpath='{.spec.containers[*].env[*].name}' 2>/dev/null); then
        warn "Unable to inspect pod '$pod_name' — skipping this runtime check"
        return
      fi
      pod_env=$(echo "$pod_env" | tr ' ' '\n')

      for env_var in AWS_CONTAINER_CREDENTIALS_FULL_URI AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE; do
        if echo "$pod_env" | grep -qx "$env_var"; then
          pass "Pod '$pod_name' has env var: $env_var"
        else
          fail "Pod '$pod_name' is MISSING env var: $env_var — Pod Identity mutation may not have occurred" \
            "Verify the pod uses service account '$service_account', confirm its EKS Pod Identity association and the eks-pod-identity-agent are ACTIVE, then restart the workload so EKS can inject the variables into a new pod."
        fi
      done
    fi
  }

  check_pod_identity_env "hubble-system" "app=spectro-hubble" "spectro-hubble" "spectro-hubble"
  check_pod_identity_env "palette-identity" "app=palette-identity" "palette-identity" "palette-identity"
fi

# ─── Final Summary ─────────────────────────────────────────────────────────────
header "Validation Summary"

if [[ "$FAILURES" -eq 0 ]]; then
  echo -e "\n${GREEN}${BOLD}  ✅  All checks passed! Your environment is ready for Palette VerteX on EKS.${RESET}\n"
else
  echo -e "\n${RED}${BOLD}  ❌  $FAILURES check(s) FAILED. Review the output above and remediate before deploying.${RESET}\n"
  echo -e "${YELLOW}  Each failure above includes a targeted FIX. After applying the relevant fixes, rerun this script.${RESET}"
  echo -e "${YELLOW}  Additional troubleshooting checklist:${RESET}"
  echo -e "  1. Attach the minimum permission policies from the Spectro Cloud IAM policy docs"
  echo -e "  2. Confirm the AWS profile, account, partition, and region match the intended environment"
  case "$AUTH_MODE" in
    secret)
      echo -e "  3. Confirm the configured access key belongs to the validated IAM user or role"
      ;;
    sts)
      echo -e "  3. Confirm the deployer trust policy and caller policies allow sts:AssumeRole and sts:TagSession"
      ;;
    pod-identity)
      echo -e "  3. Ensure Pod Identity roles trust pods.eks.amazonaws.com for sts:AssumeRole and sts:TagSession"
      echo -e "  4. Confirm the eks-pod-identity-agent addon and service-account associations are active"
      echo -e "  5. Set managementClusterName in palette-global-config and restart workloads after association changes"
      ;;
  esac
  echo
  exit 1
fi
