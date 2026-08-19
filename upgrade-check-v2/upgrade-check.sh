#!/usr/bin/env bash

set -uo pipefail
umask 077

VERSION="2.1.0"
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
COMMON_CONFIG="${SCRIPT_DIR}/../config/common-config.sh"
COMMON_FUNCTIONS="${SCRIPT_DIR}/../config/common-functions.sh"
# shellcheck source=../config/common-config.sh
source "${COMMON_CONFIG}"
# shellcheck source=../config/common-functions.sh
source "${COMMON_FUNCTIONS}"
RUN_ID=$(date +%Y%m%d-%H%M%S)

# Defaults may be overridden by environment variables or command-line options.
MGMT_NAMESPACE="${MGMT_NAMESPACE:-${NAMESPACE:-hubble-system}}"
MONGO_NAMESPACE="${MONGO_NAMESPACE:-${MONGO_NS:-}}"
PIRAEUS_NAMESPACE="${PIRAEUS_NAMESPACE:-${PIRAEUS_NS:-piraeus-system}}"
MONGO_SECRET="${MONGO_SECRET:-spectromongosecret}"
MONGO_POD="${MONGO_POD:-${MONGO_QUERY_POD:-mongo-0}}"
TARGET_VERSION="${TARGET_VERSION:-}"
OUTPUT_DIR="${OUTPUT_DIR:-}"
KUBE_CONTEXT="${KUBE_CONTEXT:-}"
VERTEX_API_URL="${VERTEX_API_URL:-}"
INSECURE_TLS="${INSECURE_TLS:-${VERTEX_API_INSECURE_TLS:-false}}"
CONFIRM_PATH="${CONFIRM_PATH:-${UPGRADE_PATH_CONFIRMED:-false}}"
CONFIRM_BREAKING="${CONFIRM_BREAKING:-${BREAKING_CHANGES_CONFIRMED:-false}}"
SKIP_ETCD_SNAPSHOT="${SKIP_ETCD_SNAPSHOT:-${SKIP_BACKUP:-false}}"
NO_COLOR="${NO_COLOR:-false}"
ZOT_NODE_PORT="${ZOT_NODE_PORT:-30003}"
REGISTRY_MAX_AGE_HOURS="${REGISTRY_MAX_AGE_HOURS:-${REGISTRY_SYNC_MAX_AGE_HOURS:-48}}"
REGISTRY_RUNNING_WARN_HOURS="${REGISTRY_RUNNING_WARN_HOURS:-${REGISTRY_SYNC_RUNNING_WARN_HOURS:-1}}"
ETCD_HELPER_IMAGE="${ETCD_HELPER_IMAGE:-${ETCD_SNAPSHOT_HELPER_IMAGE:-busybox:1.28}}"
DNS_TEST_IMAGE="${DNS_TEST_IMAGE:-busybox:1.28}"
UPGRADE_URL="${UPGRADE_URL:-https://docs.spectrocloud.com/vertex/upgrade/}"
BREAKING_URL="${BREAKING_URL:-https://docs.spectrocloud.com/release-notes/breaking-changes/}"

usage() {
  cat <<'USAGE'
Palette VerteX pre-upgrade health check v2

Usage:
  ./upgrade-check.sh [options]
  ./upgrade-check.sh --help

Upgrade review:
  -t, --target VERSION              Target VerteX version; prompted when omitted
      --confirm-path                Confirm the documented upgrade path was reviewed
      --confirm-breaking-changes    Confirm applicable breaking changes were addressed

Cluster selection:
  -c, --context NAME                kubectl context (default: current context)
  -n, --namespace NAME              Palette namespace (default: hubble-system)
      --mongo-namespace NAME        MongoDB namespace (default: Palette namespace)
      --piraeus-namespace NAME      Piraeus namespace (default: piraeus-system)

Connectivity:
      --api-url URL                 VerteX API base URL, without /system
  -k, --insecure                    Skip TLS verification for registry API checks

Recovery and output:
  -o, --output PATH                 Artifact directory (default: local artifacts folder)
      --skip-etcd-snapshot          Run checks without creating an etcd snapshot
      --no-color                    Disable colored status labels

General:
  -h, --help                        Show this help
      --version                     Print the script version

Examples:
  ./upgrade-check.sh -t 4.9.38 -o ./preupgrade-artifacts

  ./upgrade-check.sh -c edge-admin@edge1 -t 4.9.38 \
    --confirm-path --confirm-breaking-changes

  VERTEX_API_KEY='...' ./upgrade-check.sh -t 4.9.38 \
    --api-url https://vertex.example.com --insecure

Credentials and advanced settings are supplied through environment variables.
See README.md for the complete list, artifacts, behavior, and exit codes.

Exit codes:
  0  No blocking failures or unknown results
  1  One or more failed checks
  2  Invalid invocation, missing prerequisite, or inconclusive checks
USAGE
}

usage_error() {
  printf 'ERROR: %s\n\n' "$1" >&2
  usage >&2
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -t|--target|--target-version)
      require_value "$1" "${2:-}"; TARGET_VERSION="$2"; shift 2 ;;
    -c|--context)
      require_value "$1" "${2:-}"; KUBE_CONTEXT="$2"; shift 2 ;;
    -n|--namespace)
      require_value "$1" "${2:-}"; MGMT_NAMESPACE="$2"; shift 2 ;;
    --mongo-namespace)
      require_value "$1" "${2:-}"; MONGO_NAMESPACE="$2"; shift 2 ;;
    --piraeus-namespace)
      require_value "$1" "${2:-}"; PIRAEUS_NAMESPACE="$2"; shift 2 ;;
    --api-url)
      require_value "$1" "${2:-}"; VERTEX_API_URL="$2"; shift 2 ;;
    -o|--output|--output-dir)
      require_value "$1" "${2:-}"; OUTPUT_DIR="$2"; shift 2 ;;
    --confirm-path|--upgrade-path-confirmed)
      CONFIRM_PATH=true; shift ;;
    --confirm-breaking-changes|--breaking-changes-confirmed)
      CONFIRM_BREAKING=true; shift ;;
    --skip-etcd-snapshot|--skip-backup)
      SKIP_ETCD_SNAPSHOT=true; shift ;;
    -k|--insecure)
      INSECURE_TLS=true; shift ;;
    --no-color)
      NO_COLOR=true; shift ;;
    --version)
      printf '%s\n' "$VERSION"; exit 0 ;;
    -h|--help)
      usage; exit 0 ;;
    --)
      shift; [[ $# -eq 0 ]] || usage_error "positional arguments are not supported" ;;
    *)
      usage_error "unknown option: $1" ;;
  esac
done

[[ -n "$MONGO_NAMESPACE" ]] || MONGO_NAMESPACE="$MGMT_NAMESPACE"
[[ -n "$OUTPUT_DIR" ]] || OUTPUT_DIR="$SCRIPT_DIR/artifacts/palette-preupgrade-$RUN_ID"

for boolean_name in INSECURE_TLS CONFIRM_PATH CONFIRM_BREAKING SKIP_ETCD_SNAPSHOT NO_COLOR; do
  eval "boolean_value=\${$boolean_name}"
  [[ "$boolean_value" == "true" || "$boolean_value" == "false" ]] \
    || usage_error "$boolean_name must be true or false"
done
validate_port ZOT_NODE_PORT "$ZOT_NODE_PORT"
[[ "$REGISTRY_MAX_AGE_HOURS" =~ ^[0-9]+$ ]] \
  || usage_error "REGISTRY_MAX_AGE_HOURS must be a whole number"
[[ "$REGISTRY_RUNNING_WARN_HOURS" =~ ^[0-9]+$ ]] \
  || usage_error "REGISTRY_RUNNING_WARN_HOURS must be a whole number"

if [[ "$NO_COLOR" == "true" || ! -t 1 ]]; then
  RED=""; YELLOW=""; GREEN=""; BLUE=""; RESET=""
else
  RED=$'\033[0;31m'; YELLOW=$'\033[1;33m'; GREEN=$'\033[0;32m'
  BLUE=$'\033[0;36m'; RESET=$'\033[0m'
fi

mkdir -p "$OUTPUT_DIR" || { printf 'ERROR: cannot create %s\n' "$OUTPUT_DIR" >&2; exit 2; }
chmod 700 "$OUTPUT_DIR"
LOG="$OUTPUT_DIR/preupgrade-check.log"
VALUES_FILE="$OUTPUT_DIR/pre-upgrade-values.env"
: > "$LOG"
: > "$VALUES_FILE"

PASS=0
WARN=0
FAIL=0
UNKNOWN=0
SECTION_NUMBER=0
SECTION_TOTAL=7
TEMP_PODS=()

kube() {
  if [[ -n "$KUBE_CONTEXT" ]]; then
    command kubectl --context "$KUBE_CONTEXT" "$@"
  else
    command kubectl "$@"
  fi
}

log() { printf '%b\n' "$*" | tee -a "$LOG"; }
pass() { log "${GREEN}[PASS]${RESET} $*"; PASS=$((PASS + 1)); }
warn() { log "${YELLOW}[WARN]${RESET} $*"; WARN=$((WARN + 1)); }
fail() { log "${RED}[FAIL]${RESET} $*"; FAIL=$((FAIL + 1)); }
unknown() { log "${YELLOW}[UNKNOWN]${RESET} $*"; UNKNOWN=$((UNKNOWN + 1)); }
info() { log "${BLUE}[INFO]${RESET} $*"; }
detail() {
  while IFS= read -r detail_line; do log "    $detail_line"; done <<< "$*"
}

title() {
  log "========================================================================"
  log "  $*"
  log "========================================================================"
}

section() {
  SECTION_NUMBER=$((SECTION_NUMBER + 1))
  log ""
  log "========================================================================"
  log "  SECTION $SECTION_NUMBER/$SECTION_TOTAL: $*"
  log "========================================================================"
}

record_value() {
  local key="$1" value="$2"
  [[ "$key" =~ ^[A-Z][A-Z0-9_]*$ ]] || return 1
  value=$(printf '%s' "$value" | tr '\r\n' '  ')
  printf '%s=%s\n' "$key" "$value" >> "$VALUES_FILE"
}

register_temp_pod() { TEMP_PODS+=("$1/$2"); }
delete_temp_pod() {
  local namespace="$1" name="$2"
  kube delete pod -n "$namespace" "$name" --ignore-not-found --wait=false \
    >>"$LOG" 2>&1 || true
}
cleanup() {
  local item namespace name index pod_count
  pod_count=${#TEMP_PODS[@]}
  (( pod_count > 0 )) || return 0
  for ((index = 0; index < pod_count; index++)); do
    item=${TEMP_PODS[$index]}
    namespace=${item%%/*}; name=${item#*/}
    delete_temp_pod "$namespace" "$name"
  done
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

source "$SCRIPT_DIR/lib/etcd.sh"

check_prerequisites() {
  local command_name missing=0
  for command_name in kubectl helm openssl curl python3 base64 awk sed grep; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
      fail "Required command not found: $command_name"
      missing=1
    fi
  done
  (( missing == 0 )) || { detail "Install missing prerequisites and rerun"; exit 2; }
  [[ -r "$SCRIPT_DIR/lib/kube_inspect.py" ]] || { fail "Missing lib/kube_inspect.py"; exit 2; }
  [[ -r "$SCRIPT_DIR/lib/registry_check.py" ]] || { fail "Missing lib/registry_check.py"; exit 2; }
  [[ -r "$SCRIPT_DIR/templates/post-upgrade-checklist.md" ]] \
    || { fail "Missing post-upgrade checklist template"; exit 2; }
}

check_pod_group() {
  local label="$1" namespace="$2" name_pattern="$3" absent_level="$4"
  local data selected unhealthy count
  if ! data=$(kube get pods -n "$namespace" --no-headers 2>>"$LOG"); then
    unknown "Could not query $label pods in $namespace"
    return
  fi
  selected=$(printf '%s\n' "$data" | awk -v pattern="$name_pattern" '$1 ~ pattern')
  if [[ -z "$selected" ]]; then
    case "$absent_level" in
      FAIL) fail "No $label pods found in $namespace" ;;
      WARN) warn "No $label pods found in $namespace" ;;
      *) info "No $label pods found in $namespace" ;;
    esac
    return
  fi
  count=$(printf '%s\n' "$selected" | awk 'NF {count++} END {print count+0}')
  unhealthy=$(printf '%s\n' "$selected" | awk '
    {
      split($2, ready, "/")
      completed = ($3 == "Completed" || $3 == "Succeeded")
      if (!completed && ($3 != "Running" || ready[1] != ready[2])) print $1, $2, $3
    }')
  if [[ -z "$unhealthy" ]]; then
    pass "$label pods are healthy ($count found in $namespace)"
  else
    fail "$label pods are unhealthy in $namespace"
    detail "$unhealthy"
  fi
}

review_gate() {
  local confirmed="$1" prompt="$2" success="$3" failure="$4"
  if [[ "$confirmed" == "true" ]] || confirm_action "$prompt"; then
    pass "$success"
    return 0
  fi
  fail "$failure"
  return 1
}

check_installation_and_review() {
  local version_json nodes_json cluster_detection detection_evidence
  section "INSTALLATION AND UPGRADE REVIEW"
  info "Checking Kubernetes API access"
  if ! kube cluster-info >>"$LOG" 2>&1; then
    fail "Cannot reach the Kubernetes API"
    exit 2
  fi

  if [[ -n "$KUBE_CONTEXT" ]]; then
    CURRENT_CONTEXT="$KUBE_CONTEXT"
  else
    CURRENT_CONTEXT=$(command kubectl config current-context 2>/dev/null || printf 'unknown')
  fi
  if ! kube get namespace "$MGMT_NAMESPACE" >/dev/null 2>>"$LOG"; then
    fail "Palette namespace is missing or unreadable: $MGMT_NAMESPACE"
    exit 2
  fi
  if [[ $(kube auth can-i get pods -n "$MGMT_NAMESPACE" 2>>"$LOG") != "yes" ]]; then
    fail "Current identity cannot read pods in $MGMT_NAMESPACE"
    exit 2
  fi
  pass "Connected to the cluster with access to $MGMT_NAMESPACE"

  CLUSTER_NAME=$(kube config view --minify \
    -o jsonpath='{.clusters[0].name}' 2>/dev/null || true)
  [[ -n "$CLUSTER_NAME" ]] || CLUSTER_NAME="$CURRENT_CONTEXT"
  VERTEX_VERSION=$(kube get configmap spectro-mgmt-version -n "$MGMT_NAMESPACE" \
    -o jsonpath='{.data.spectro-mgmt-version-current}' 2>/dev/null || true)
  [[ -n "$VERTEX_VERSION" ]] || VERTEX_VERSION="unknown"
  version_json=$(kube version -o json 2>/dev/null || true)
  KUBERNETES_VERSION=$(printf '%s' "$version_json" \
    | python3 "$SCRIPT_DIR/lib/kube_inspect.py" server-version 2>>"$LOG" || printf 'unknown')
  API_SERVER=$(kube config view --minify \
    -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || true)
  nodes_json=$(kube get nodes -o json 2>>"$LOG" || printf '{"items":[]}')
  cluster_detection=$(printf '%s' "$nodes_json" \
    | python3 "$SCRIPT_DIR/lib/kube_inspect.py" cluster-type \
      "$KUBERNETES_VERSION" "$CURRENT_CONTEXT" "$CLUSTER_NAME" "$API_SERVER" \
      2>>"$LOG" || true)
  IFS=$'\t' read -r CONTROL_PLANE_MODE CLUSTER_TYPE CLUSTER_PLATFORM detection_evidence \
    <<< "$cluster_detection"
  [[ -n "${CONTROL_PLANE_MODE:-}" ]] || CONTROL_PLANE_MODE="unknown"
  [[ -n "${CLUSTER_TYPE:-}" ]] || CLUSTER_TYPE="UNKNOWN"
  [[ -n "${CLUSTER_PLATFORM:-}" ]] || CLUSTER_PLATFORM="Unclassified Kubernetes"

  detail "Context: $CURRENT_CONTEXT"
  detail "Cluster: $CLUSTER_NAME"
  info "Detected cluster type: $CLUSTER_PLATFORM ($CONTROL_PLANE_MODE control plane)"
  [[ -z "${detection_evidence:-}" ]] || detail "Detection: $detection_evidence"
  detail "VerteX: $VERTEX_VERSION"
  detail "Kubernetes: $KUBERNETES_VERSION"
  record_value CLUSTER_NAME "$CLUSTER_NAME"
  record_value KUBE_CONTEXT "$CURRENT_CONTEXT"
  record_value VERTEX_VERSION "$VERTEX_VERSION"
  record_value KUBERNETES_VERSION "$KUBERNETES_VERSION"
  record_value CLUSTER_TYPE "$CLUSTER_TYPE"
  record_value CLUSTER_PLATFORM "$CLUSTER_PLATFORM"
  record_value CONTROL_PLANE_MODE "$CONTROL_PLANE_MODE"
  record_value API_SERVER "$API_SERVER"
  record_value MGMT_NAMESPACE "$MGMT_NAMESPACE"
  record_value MONGO_NAMESPACE "$MONGO_NAMESPACE"
  record_value PIRAEUS_NAMESPACE "$PIRAEUS_NAMESPACE"

  if [[ -z "$TARGET_VERSION" && -t 0 ]]; then
    printf 'Target VerteX version: '
    IFS= read -r TARGET_VERSION || TARGET_VERSION=""
  fi
  if [[ -z "$TARGET_VERSION" ]]; then
    fail "A target version is required; use --target VERSION"
    return
  fi
  if [[ ! "$TARGET_VERSION" =~ ^v?[0-9]+(\.[0-9]+){1,3}([.-][0-9A-Za-z]+)*$ ]]; then
    fail "Target version is not recognized: $TARGET_VERSION"
    return
  fi
  record_value TARGET_VERSION "$TARGET_VERSION"
  detail "Upgrade: $VERTEX_VERSION → $TARGET_VERSION"

  log ""
  info "Review the supported upgrade-path table: $UPGRADE_URL"
  if review_gate "$CONFIRM_PATH" \
    "Is the $VERTEX_VERSION → $TARGET_VERSION path documented as supported?" \
    "Supported upgrade path was confirmed" \
    "Supported upgrade path was not confirmed"; then
    CONFIRM_PATH=true
  fi

  info "Review all applicable breaking changes: $BREAKING_URL"
  if review_gate "$CONFIRM_BREAKING" \
    "Have all breaking changes for $VERTEX_VERSION → $TARGET_VERSION been addressed?" \
    "Breaking changes were reviewed and addressed" \
    "Breaking changes were not confirmed as addressed"; then
    CONFIRM_BREAKING=true
  fi
  record_value UPGRADE_PATH_CONFIRMED "$CONFIRM_PATH"
  record_value BREAKING_CHANGES_CONFIRMED "$CONFIRM_BREAKING"
}

check_platform() {
  local data nodes_json count unhealthy control_plane_count backoffs workloads helm_secret_count
  local helm_version helm_major helm_minor
  section "CLUSTER AND PALETTE HEALTH"

  info "Checking node readiness"
  if data=$(kube get nodes --no-headers 2>>"$LOG"); then
    count=$(printf '%s\n' "$data" | awk 'NF {count++} END {print count+0}')
    unhealthy=$(printf '%s\n' "$data" \
      | awk '$2 != "Ready" && $2 != "Ready,SchedulingDisabled" {print $1, $2}')
    if [[ "$count" -eq 0 ]]; then
      fail "No Kubernetes nodes were returned"
    elif [[ -z "$unhealthy" ]]; then
      pass "All $count Kubernetes nodes are Ready"
    else
      fail "One or more Kubernetes nodes are not Ready"
      detail "$unhealthy"
    fi
    printf '%s\n' "$data" >> "$LOG"
  else
    unknown "Could not query Kubernetes nodes"
  fi

  nodes_json=$(kube get nodes -o json 2>>"$LOG" || true)
  if [[ "$CONTROL_PLANE_MODE" == "managed" ]]; then
    info "$CLUSTER_PLATFORM uses a provider-managed control plane; control-plane nodes and their count are not exposed as Kubernetes Node objects"
  elif [[ -n "$nodes_json" ]] \
    && control_plane_count=$(printf '%s' "$nodes_json" \
      | python3 "$SCRIPT_DIR/lib/kube_inspect.py" control-plane-count 2>>"$LOG"); then
    if [[ "$control_plane_count" -ge 3 ]]; then
      pass "Control plane has $control_plane_count nodes"
    elif [[ "$control_plane_count" -eq 1 ]]; then
      warn "Single control-plane node detected; upgrade risk is higher"
    else
      warn "Control-plane count is $control_plane_count; verify the topology and quorum"
    fi
  else
    unknown "Could not determine control-plane node count"
  fi

  info "Collecting node resource usage"
  if kube top nodes >>"$LOG" 2>&1; then
    pass "Worker node metrics are available"
    if [[ "$CONTROL_PLANE_MODE" == "managed" ]]; then
      info "$CLUSTER_PLATFORM control-plane metrics are provider-managed and are not included in kubectl top nodes"
    fi
  elif [[ "$CONTROL_PLANE_MODE" == "managed" ]]; then
    info "The in-cluster node metrics API is unavailable; $CLUSTER_PLATFORM control-plane metrics remain provider-managed"
    detail "Review worker-node resource headroom through your cloud monitoring service or install a supported metrics provider."
  else
    warn "Node metrics are unavailable; verify resource headroom manually"
  fi

  check_pod_group "Palette management" "$MGMT_NAMESPACE" "." FAIL

  if data=$(kube get pods -A --no-headers 2>>"$LOG"); then
    backoffs=$(printf '%s\n' "$data" \
      | awk '$4 ~ /CrashLoopBackOff|ImagePullBackOff|ErrImagePull/ {print $1, $2, $4}')
    if [[ -z "$backoffs" ]]; then
      pass "No CrashLoopBackOff or image-pull failures found cluster-wide"
    else
      fail "CrashLoopBackOff or image-pull failures were detected"
      detail "$backoffs"
    fi
  else
    unknown "Could not scan cluster-wide pod failures"
  fi

  if data=$(kube get deploy,statefulset -n "$MGMT_NAMESPACE" --no-headers 2>>"$LOG"); then
    workloads=$(printf '%s\n' "$data" \
      | awk '{split($2, replicas, "/"); if (replicas[1] != replicas[2]) print $1, $2}')
    if [[ -z "$workloads" ]]; then
      pass "Palette Deployments and StatefulSets are fully replicated"
    else
      fail "Under-replicated Palette workloads were detected"
      detail "$workloads"
    fi
  else
    unknown "Could not query Palette Deployments and StatefulSets"
  fi

  if data=$(kube get secrets -n "$MGMT_NAMESPACE" -l owner=helm \
    --no-headers 2>>"$LOG"); then
    helm_secret_count=$(printf '%s\n' "$data" | awk 'NF {count++} END {print count+0}')
    if [[ "$helm_secret_count" -gt 500 ]]; then
      fail "Helm release secret count is $helm_secret_count (etcd bloat risk)"
    elif [[ "$helm_secret_count" -gt 100 ]]; then
      warn "Helm release secret count is high: $helm_secret_count"
    else
      pass "Helm release secret count is healthy: $helm_secret_count"
    fi
  else
    unknown "Could not query Helm release Secrets"
  fi

  helm_version=$(helm version --template '{{.Version}}' 2>/dev/null || true)
  if [[ "$helm_version" =~ ^v?([0-9]+)\.([0-9]+) ]]; then
    helm_major=${BASH_REMATCH[1]}; helm_minor=${BASH_REMATCH[2]}
    if [[ "$helm_major" -gt 3 || ( "$helm_major" -eq 3 && "$helm_minor" -ge 14 ) ]]; then
      pass "Helm $helm_version meets the minimum version (3.14)"
    else
      fail "Helm $helm_version is older than the required 3.14"
    fi
  else
    warn "Could not determine the Helm client version"
    helm_version="unknown"
  fi
  record_value HELM_VERSION "$helm_version"
}

mongo_replica_status() {
  local encoded password
  encoded=$(kube get secret -n "$MONGO_NAMESPACE" "$MONGO_SECRET" \
    -o jsonpath='{.data.mongoRootPassword}' 2>>"$LOG") || return 1
  password=$(printf '%s' "$encoded" | base64 -d 2>>"$LOG") || return 1
  [[ -n "$password" ]] || return 1
  kube exec -n "$MONGO_NAMESPACE" "$MONGO_POD" -c mongo -- \
    env OPENSSL_CONF=/dev/null mongosh --port 27017 -u root -p "$password" \
    --authenticationDatabase admin --tls \
    --tlsCAFile /var/mongodb/tls/ca.crt \
    --tlsCertificateKeyFile /var/mongodb/tls/tls-combined.pem \
    --tlsAllowInvalidHostnames --quiet \
    --eval 'JSON.stringify(rs.status().members.map(m => ({name:m.name,state:m.stateStr,health:m.health,optime:m.optimeDate})))'
}

check_mongodb_and_storage() {
  local status primary data unbound pressure markers
  section "MONGODB AND STORAGE"

  check_pod_group "MongoDB" "$MONGO_NAMESPACE" "^mongo-" WARN
  info "Checking the MongoDB replica set"
  if ! kube get pod -n "$MONGO_NAMESPACE" "$MONGO_POD" >/dev/null 2>>"$LOG"; then
    fail "MongoDB query pod not found: $MONGO_NAMESPACE/$MONGO_POD"
  elif status=$(mongo_replica_status 2>>"$LOG"); then
    printf '%s\n' "$status" >> "$LOG"
    primary=$(printf '%s' "$status" | python3 -c 'import json, sys
members = json.load(sys.stdin)
primary = next((m.get("name", "") for m in members if m.get("state") == "PRIMARY" and m.get("health") == 1), "")
print(primary.split(":", 1)[0].split(".", 1)[0])
' 2>>"$LOG" || true)
    if [[ -n "$primary" ]]; then
      pass "MongoDB replica set is healthy; primary is $primary"
      record_value MONGO_PRIMARY "$primary"
    else
      fail "MongoDB replica set has no healthy primary"
    fi
  else
    fail "Authenticated MongoDB replica-set query failed"
  fi

  if data=$(kube get pvc -n "$MONGO_NAMESPACE" --no-headers 2>>"$LOG"); then
    if [[ -z "$data" ]]; then
      warn "No MongoDB PVCs were found in $MONGO_NAMESPACE"
    else
      unbound=$(printf '%s\n' "$data" | awk '$2 != "Bound" {print $1, $2}')
      if [[ -z "$unbound" ]]; then
        pass "All MongoDB PVCs are Bound"
      else
        fail "One or more MongoDB PVCs are not Bound"
        detail "$unbound"
      fi
    fi
  else
    unknown "Could not query MongoDB PVCs"
  fi

  if data=$(kube get pvc -A --no-headers 2>>"$LOG"); then
    unbound=$(printf '%s\n' "$data" | awk '$3 != "Bound" {print $1, $2, $3}')
    if [[ -z "$unbound" ]]; then
      pass "All cluster PVCs are Bound"
    else
      fail "One or more cluster PVCs are not Bound"
      detail "$unbound"
    fi
  else
    unknown "Could not query cluster PVCs"
  fi

  if pressure=$(kube get nodes -o json 2>>"$LOG" \
    | python3 "$SCRIPT_DIR/lib/kube_inspect.py" disk-pressure 2>>"$LOG"); then
    if [[ -z "$pressure" ]]; then
      pass "No nodes report DiskPressure"
    else
      fail "Nodes reporting DiskPressure: $pressure"
    fi
  else
    unknown "Could not evaluate node DiskPressure"
  fi

  markers=$(kube get crd -o name 2>/dev/null | grep -Ei 'piraeus|linstor' || true)
  if kube get namespace "$PIRAEUS_NAMESPACE" >/dev/null 2>&1; then
    check_pod_group "Piraeus/LINSTOR" "$PIRAEUS_NAMESPACE" "." FAIL
  elif [[ -n "$markers" ]]; then
    fail "Piraeus CRDs exist, but namespace $PIRAEUS_NAMESPACE is missing"
  else
    info "Piraeus/LINSTOR is not installed; skipping its pod check"
  fi
}

discover_traefik_endpoint() {
  TRAEFIK_ENDPOINT=$(kube get services -n ingress-traefik \
    -o jsonpath='{range .items[*].status.loadBalancer.ingress[*]}{.hostname}{.ip}{"\n"}{end}' \
    2>>"$LOG" | awk 'NF {print; exit}' || true)
}

check_certificates_and_ingress() {
  local tls_secrets expiry traefik_crds ingress_classes nginx
  section "CERTIFICATES AND INGRESS"

  check_pod_group "cert-manager" cert-manager "." FAIL

  tls_secrets=$(kube get secrets -n "$MGMT_NAMESPACE" \
    -o custom-columns='NAME:.metadata.name,TYPE:.type' --no-headers 2>>"$LOG" \
    | awk '$2 == "kubernetes.io/tls" {print $1}' || true)
  if [[ -n "$tls_secrets" ]]; then
    warn "Custom TLS certificates are present and must be preserved"
    detail "$tls_secrets"
  else
    info "No custom TLS secrets found in $MGMT_NAMESPACE"
  fi

  check_pod_group "Traefik" ingress-traefik "." WARN
  discover_traefik_endpoint
  if [[ -n "$TRAEFIK_ENDPOINT" ]]; then
    pass "Traefik LoadBalancer endpoint: $TRAEFIK_ENDPOINT"
    record_value TRAEFIK_ENDPOINT "$TRAEFIK_ENDPOINT"
    expiry=$(printf '' | openssl s_client -connect "$TRAEFIK_ENDPOINT:443" \
      -servername "$TRAEFIK_ENDPOINT" 2>/dev/null \
      | openssl x509 -noout -enddate 2>/dev/null || true)
    if [[ -n "$expiry" ]]; then
      pass "Palette endpoint certificate is readable ($expiry)"
    else
      warn "Could not read the certificate presented by $TRAEFIK_ENDPOINT:443"
    fi
  else
    warn "Traefik LoadBalancer has no external hostname or IP"
  fi

  nginx=$(kube get pods -A --no-headers 2>/dev/null \
    | awk '$2 ~ /ingress-nginx/ {print $1, $2, $4}' || true)
  if [[ -n "$nginx" ]]; then
    warn "Legacy ingress-nginx pods are still present"
    detail "$nginx"
  else
    pass "No legacy ingress-nginx pods detected"
  fi

  traefik_crds=$(kube get crd -o name 2>>"$LOG" \
    | grep -E 'traefik.io|traefik.containo.us' || true)
  if [[ -n "$traefik_crds" ]]; then
    pass "Traefik CRDs are installed ($(printf '%s\n' "$traefik_crds" | awk 'NF {count++} END {print count+0}') found)"
  else
    fail "No Traefik CRDs were found"
  fi

  ingress_classes=$(kube get ingressclass -o name 2>>"$LOG" | grep -i traefik || true)
  if [[ -n "$ingress_classes" ]]; then
    pass "Traefik IngressClass is installed"
  else
    warn "No Traefik IngressClass was found"
  fi
}

check_zot() {
  local services count namespace name type service_port target_port node_port protocol
  local endpoint_counts ready total
  info "Checking Zot NodePort $ZOT_NODE_PORT across all namespaces"
  if ! services=$(kube get services -A -o json 2>>"$LOG" \
    | python3 "$SCRIPT_DIR/lib/kube_inspect.py" zot-services "$ZOT_NODE_PORT" 2>>"$LOG"); then
    unknown "Could not query Services for Zot NodePort $ZOT_NODE_PORT"
    return
  fi
  if [[ -z "$services" ]]; then
    warn "No Service exposes expected Zot NodePort $ZOT_NODE_PORT"
    return
  fi

  count=$(printf '%s\n' "$services" | awk 'NF {count++} END {print count+0}')
  pass "Found $count Service(s) exposing Zot NodePort $ZOT_NODE_PORT"
  while IFS=$'\t' read -r namespace name type service_port target_port node_port protocol; do
    [[ -n "$namespace" && -n "$name" ]] || continue
    detail "$namespace/$name: type=$type servicePort=$service_port targetPort=$target_port nodePort=$node_port/$protocol"
    if endpoint_counts=$(kube get endpointslices -n "$namespace" \
      -l "kubernetes.io/service-name=$name" -o json 2>>"$LOG" \
      | python3 "$SCRIPT_DIR/lib/kube_inspect.py" ready-endpoints 2>>"$LOG"); then
      IFS=$'\t' read -r ready total <<< "$endpoint_counts"
      if [[ "$ready" =~ ^[0-9]+$ && "$ready" -gt 0 ]]; then
        pass "Zot Service $namespace/$name has $ready ready endpoint(s)"
      else
        warn "Zot Service $namespace/$name has no ready endpoints ($total discovered)"
      fi
    else
      unknown "Could not query EndpointSlices for $namespace/$name"
    fi
  done <<< "$services"
}

run_registry_check() {
  local api_url="$1" events report status level message
  if [[ -z "${VERTEX_API_KEY:-}" && -z "${VERTEX_AUTH_TOKEN:-}" ]]; then
    warn "Registry synchronization check skipped; set VERTEX_API_KEY or VERTEX_AUTH_TOKEN"
    return
  fi

  events="$OUTPUT_DIR/.registry-events-$RUN_ID"
  report="$OUTPUT_DIR/registry-sync-status.json"
  status=0
  registry_args=(
    --url "$api_url"
    --report "$report"
    --max-age-hours "$REGISTRY_MAX_AGE_HOURS"
    --running-warn-hours "$REGISTRY_RUNNING_WARN_HOURS"
  )
  [[ "$INSECURE_TLS" == "false" ]] || registry_args+=(--insecure)
  python3 "$SCRIPT_DIR/lib/registry_check.py" "${registry_args[@]}" \
    > "$events" 2>>"$LOG" || status=$?

  if [[ ! -s "$events" ]]; then
    warn "Registry synchronization check returned no results"
  else
    while IFS=$'\t' read -r level message; do
      case "$level" in
        PASS) pass "$message" ;;
        WARN) warn "$message" ;;
        INFO) info "$message" ;;
        ERROR) warn "Registry API check failed: $message" ;;
      esac
    done < "$events"
  fi
  rm -f -- "$events"
  [[ "$status" -eq 0 ]] || detail "Registry helper exited with status $status"
  [[ ! -s "$report" ]] || info "Registry report: $report"
}

check_connectivity_and_registries() {
  local data count unhealthy dns_name api_url http_code
  section "CONNECTIVITY AND REGISTRIES"

  check_zot

  if data=$(kube get pods -n kube-system --no-headers 2>>"$LOG"); then
    count=$(printf '%s\n' "$data" | awk '$1 ~ /^coredns-/ {count++} END {print count+0}')
    unhealthy=$(printf '%s\n' "$data" \
      | awk '$1 ~ /^coredns-/ {split($2,r,"/"); if ($3 != "Running" || r[1] != r[2]) print $1,$2,$3}')
    if [[ "$count" -eq 0 ]]; then
      unknown "No CoreDNS pods found; the cluster may use another DNS provider"
    elif [[ -z "$unhealthy" ]]; then
      pass "CoreDNS pods are healthy ($count found)"
    else
      fail "CoreDNS pods are unhealthy"
      detail "$unhealthy"
    fi
  else
    unknown "Could not query cluster DNS pods"
  fi

  dns_name="dns-test-$$"
  if kube run "$dns_name" --image="$DNS_TEST_IMAGE" --restart=Never --rm -i \
    --pod-running-timeout=30s --command -- nslookup kubernetes.default.svc.cluster.local \
    >>"$LOG" 2>&1; then
    pass "In-cluster DNS resolution works"
  else
    warn "In-cluster DNS test failed or timed out"
  fi

  api_url="${VERTEX_API_URL%/}"
  if [[ "$api_url" == */system ]]; then
    api_url=${api_url%/system}
    warn "Removed /system from the supplied API URL"
  fi
  if [[ -z "$api_url" && -n "${TRAEFIK_ENDPOINT:-}" ]]; then
    api_url="https://$TRAEFIK_ENDPOINT"
  fi
  if [[ -z "$api_url" ]]; then
    warn "Could not determine the VerteX API URL; API and registry checks were skipped"
    return
  fi
  record_value VERTEX_API_URL "$api_url"

  http_code=$(curl -sk -o /dev/null -w '%{http_code}' \
    "$api_url/v1/health" --max-time 10 || true)
  if [[ "$http_code" == "200" ]]; then
    pass "Palette API health endpoint returned HTTP 200"
  else
    warn "Palette API health endpoint returned HTTP ${http_code:-000}"
  fi
  run_registry_check "$api_url"
}

backup_resource() {
  local label="$1" destination="$2"
  shift 2
  if kube "$@" > "$destination" 2>>"$LOG"; then
    pass "$label saved: $destination"
  else
    warn "Could not save $label"
  fi
}

collect_recovery_artifacts() {
  local namespace pull_secret tls_names tls_name configmaps_json version_configmap
  local tls_args=()
  section "RECOVERY READINESS"

  check_etcd

  backup_resource "Palette Secrets" "$OUTPUT_DIR/secrets-$MGMT_NAMESPACE.yaml" \
    get secrets -n "$MGMT_NAMESPACE" -o yaml
  backup_resource "Palette ConfigMaps" "$OUTPUT_DIR/configmaps-$MGMT_NAMESPACE.yaml" \
    get configmaps -n "$MGMT_NAMESPACE" -o yaml

  for namespace in hubble-system kube-system ui-system cp-system jet-system; do
    pull_secret=$(kube get secret spectro-image-pull-secret -n "$namespace" \
      -o yaml 2>/dev/null || true)
    if [[ -n "$pull_secret" ]]; then
      printf '%s\n' "$pull_secret" > "$OUTPUT_DIR/image-pull-secret-$namespace.yaml"
      pass "Image-pull Secret saved from $namespace"
    fi
  done

  tls_names=$(kube get secrets -n "$MGMT_NAMESPACE" \
    -o jsonpath='{range .items[?(@.type=="kubernetes.io/tls")]}{.metadata.name}{"\n"}{end}' \
    2>/dev/null || true)
  if [[ -n "$tls_names" ]]; then
    while IFS= read -r tls_name; do
      [[ -n "$tls_name" ]] && tls_args+=("$tls_name")
    done <<< "$tls_names"
    backup_resource "TLS Secrets" "$OUTPUT_DIR/tls-secrets-backup.yaml" \
      get secrets -n "$MGMT_NAMESPACE" "${tls_args[@]}" -o yaml
  fi

  if kube get secret linstor-passphrase -n "$PIRAEUS_NAMESPACE" >/dev/null 2>&1; then
    if kube get secret linstor-passphrase -n "$PIRAEUS_NAMESPACE" -o yaml \
      > "$OUTPUT_DIR/linstor-passphrase-backup.yaml" 2>>"$LOG"; then
      warn "LINSTOR passphrase was backed up; preserve it outside the cluster"
      detail "$OUTPUT_DIR/linstor-passphrase-backup.yaml"
    else
      fail "LINSTOR passphrase exists but could not be backed up"
    fi
  fi

  configmaps_json=$(kube get configmaps -n "$MGMT_NAMESPACE" -o json 2>>"$LOG" || true)
  version_configmap=$(printf '%s' "$configmaps_json" \
    | python3 "$SCRIPT_DIR/lib/kube_inspect.py" version-configmap 2>>"$LOG" || true)
  if [[ -n "$version_configmap" ]] \
    && kube get configmap "$version_configmap" -n "$MGMT_NAMESPACE" -o yaml \
      > "$OUTPUT_DIR/palette-version-info.yaml" 2>>"$LOG"; then
    pass "Palette version ConfigMap saved from $MGMT_NAMESPACE/$version_configmap"
    record_value PALETTE_VERSION_CONFIGMAP "$version_configmap"
  elif [[ -n "$configmaps_json" ]]; then
    warn "No recognized Palette version ConfigMap was found in $MGMT_NAMESPACE"
  else
    warn "Palette ConfigMaps could not be queried to select version metadata"
  fi
  kube get configmaps -n "$MGMT_NAMESPACE" -o yaml 2>>"$LOG" \
    | grep -A2 -E 'version|release|build' \
    > "$OUTPUT_DIR/palette-version-snapshot.txt" || true

  log ""
  info "MongoDB backup prerequisite"
  detail "This script does not create a MongoDB backup."
  detail "Before upgrading, create a fresh supported backup, store it off-cluster on encrypted storage, and verify the restore procedure."
}

write_post_upgrade_checklist() {
  section "POST-UPGRADE PLAN"
  if awk -v mgmt="$MGMT_NAMESPACE" -v mongo="$MONGO_NAMESPACE" \
    -v piraeus="$PIRAEUS_NAMESPACE" '
      { gsub("{{MGMT_NAMESPACE}}", mgmt); gsub("{{MONGO_NAMESPACE}}", mongo); gsub("{{PIRAEUS_NAMESPACE}}", piraeus); print }
    ' "$SCRIPT_DIR/templates/post-upgrade-checklist.md" \
    > "$OUTPUT_DIR/post-upgrade-checklist.md"; then
    pass "Post-upgrade checklist written: $OUTPUT_DIR/post-upgrade-checklist.md"
  else
    fail "Could not write the post-upgrade checklist"
  fi
}

print_summary() {
  log ""
  title "PRE-UPGRADE RESULT"
  log "  PASS     : $PASS"
  log "  WARN     : $WARN"
  log "  FAIL     : $FAIL"
  log "  UNKNOWN  : $UNKNOWN"
  log "------------------------------------------------------------------------"
  log "  Artifacts: $OUTPUT_DIR"
  log "========================================================================"
  if (( FAIL > 0 )); then
    log "RESULT: NOT SAFE TO UPGRADE — resolve every failure first."
    return 1
  fi
  if (( UNKNOWN > 0 )); then
    log "RESULT: INCONCLUSIVE — resolve unknown checks before upgrading."
    return 2
  fi
  log "RESULT: No blocking failures detected. Review all warnings before upgrading."
  return 0
}

title "PALETTE VERTEX PRE-UPGRADE HEALTH CHECK v$VERSION"
log "  Started : $(date)"
log "  Output  : $OUTPUT_DIR"
log "========================================================================"

check_prerequisites
check_installation_and_review
check_platform
check_mongodb_and_storage
check_certificates_and_ingress
check_connectivity_and_registries
collect_recovery_artifacts
write_post_upgrade_checklist

print_summary
exit $?
