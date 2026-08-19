#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

readonly VERSION="2.0.0"
readonly SCRIPT_NAME="${0##*/}"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly COMMON_CONFIG="${SCRIPT_DIR}/../config/common-config.sh"
readonly COMMON_FUNCTIONS="${SCRIPT_DIR}/../config/common-functions.sh"
# shellcheck source=../config/common-config.sh
source "${COMMON_CONFIG}"
# shellcheck source=../config/common-functions.sh
source "${COMMON_FUNCTIONS}"
readonly INSTALLER="$SCRIPT_DIR/install-prerequisites.sh"
readonly TOOLS_VERSION="100.17.0"
readonly RUN_ID="$(date +%Y%m%d-%H%M%S)"
readonly -a DATABASES=(hubbledb hubble_timeseriesdb hubble_archivedb)
readonly OPTIONAL_DATABASE="hubble_archivedb"

KUBECONFIG_FILE=""
NAMESPACE="hubble-system"
ARTIFACTS_DIR="$SCRIPT_DIR/artifacts"
MONGO_QUERY_POD="mongo-0"
MONGO_LOCAL_PORT=""
AGENT_UPGRADE_PAUSED=false
CHECK_ONLY=false
DRY_RUN=false

MONGO_PORT="${MONGO_PORT:-27017}"
MONGO_USER="${MONGO_USER:-root}"
AUTH_DB="${AUTH_DB:-admin}"
MONGO_SECRET="${MONGO_SECRET:-spectromongosecret}"

RUN_NAME=""
LOG_FILE=""
BACKUP_DIR=""
BACKUP_STARTED=false
PORT_FORWARD_PID=""
TEMP_DIR=""
PRIMARY_POD=""
MONGO_SERVER_VERSION=""
MONGO_DATABASES=""
MONGODUMP_VERSION=""
MONGODUMP_TLS_STYLE=""
LOG_ACTIVE=false

if [[ -t 1 ]]; then
  RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'
  BLUE=$'\033[0;36m'; RESET=$'\033[0m'
else
  RED=""; GREEN=""; YELLOW=""; BLUE=""; RESET=""
fi

info() {
  if [[ "$LOG_ACTIVE" == "true" ]]; then
    printf '[INFO] %s\n' "$*"
    printf '%s[INFO]%s %s\n' "$BLUE" "$RESET" "$*" >&3
  else
    printf '%s[INFO]%s %s\n' "$BLUE" "$RESET" "$*"
  fi
}
pass() {
  if [[ "$LOG_ACTIVE" == "true" ]]; then
    printf '[PASS] %s\n' "$*"
    printf '%s[PASS]%s %s\n' "$GREEN" "$RESET" "$*" >&3
  else
    printf '%s[PASS]%s %s\n' "$GREEN" "$RESET" "$*"
  fi
}
warn() {
  if [[ "$LOG_ACTIVE" == "true" ]]; then
    printf '[WARN] %s\n' "$*"
    printf '%s[WARN]%s %s\n' "$YELLOW" "$RESET" "$*" >&3
  else
    printf '%s[WARN]%s %s\n' "$YELLOW" "$RESET" "$*"
  fi
}

artifact_security_warning() {
  warn "========================================================================"
  warn "SECURITY NOTICE: PROTECT THE BACKUP ARTIFACTS"
  warn "MongoDB data and Kubernetes Secrets are stored in:"
  warn "$BACKUP_DIR"
  warn "Move this directory to approved encrypted storage and restrict access."
  warn "========================================================================"
}

fail() {
  if [[ "$LOG_ACTIVE" == "true" ]]; then
    printf '[ERROR] %s\n' "$*" >&2
    printf '%s[ERROR]%s %s\n' "$RED" "$RESET" "$*" >&4
  else
    printf '%s[ERROR]%s %s\n' "$RED" "$RESET" "$*" >&2
  fi
}

usage() {
  cat <<'USAGE'
Palette EC MongoDB backup v2

Usage:
  ./palette-ec-backup.sh --kubeconfig FILE --agent-upgrade-paused [options]
  ./palette-ec-backup.sh --check-prerequisites [options]
  ./palette-ec-backup.sh --help

Required for a backup:
  -k, --kubeconfig FILE          Source-cluster kubeconfig
      --agent-upgrade-paused     Confirm Pause Agent Upgrade is enabled

Options:
  -n, --namespace NAME           Palette namespace (default: hubble-system)
  -a, --artifacts-dir DIR        Artifact root (default: ./artifacts beside script)
      --mongo-pod NAME           Pod used to query replica status (default: mongo-0)
      --local-port PORT          Fixed loopback port (default: select a free port)
      --check-prerequisites      Check local tools and bundled packages, then exit
      --dry-run                  Check prerequisites and display the backup plan
  -h, --help                     Show this help
      --version                  Print the script version

Every run writes a timestamped log beneath the artifact root. A successful
backup is written to artifacts/palette-mongo-backup-YYYYmmdd-HHMMSS/.

Advanced environment overrides:
  MONGO_PORT, MONGO_USER, AUTH_DB, MONGO_SECRET

Exit codes:
  0  Success
  1  Prerequisite, cluster, or backup failure
  2  Invalid command-line usage
USAGE
}

usage_error() {
  fail "$1"
  printf '\n' >&2
  usage >&2
  exit 2
}

parse_args() {
  while (($#)); do
    case "$1" in
      -k|--kubeconfig)
        require_value "$1" "${2:-}"; KUBECONFIG_FILE="$2"; shift 2 ;;
      -n|--namespace)
        require_value "$1" "${2:-}"; NAMESPACE="$2"; shift 2 ;;
      -a|--artifacts-dir)
        require_value "$1" "${2:-}"; ARTIFACTS_DIR="$2"; shift 2 ;;
      --mongo-pod)
        require_value "$1" "${2:-}"; MONGO_QUERY_POD="$2"; shift 2 ;;
      --local-port)
        require_value "$1" "${2:-}"; MONGO_LOCAL_PORT="$2"; shift 2 ;;
      --agent-upgrade-paused)
        AGENT_UPGRADE_PAUSED=true; shift ;;
      --check-prerequisites)
        CHECK_ONLY=true; shift ;;
      --dry-run)
        DRY_RUN=true; shift ;;
      --version)
        printf '%s\n' "$VERSION"; exit 0 ;;
      -h|--help)
        usage; exit 0 ;;
      *)
        usage_error "unknown option: $1" ;;
    esac
  done
}

validate_args() {
  [[ "$ARTIFACTS_DIR" != "/" ]] || usage_error "refusing to use / as the artifact root"
  [[ "$NAMESPACE" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] \
    || usage_error "invalid Kubernetes namespace: $NAMESPACE"
  [[ "$MONGO_QUERY_POD" =~ ^[a-z0-9]([-a-z0-9.]*[a-z0-9])?$ ]] \
    || usage_error "invalid MongoDB pod name: $MONGO_QUERY_POD"
  [[ "$MONGO_PORT" =~ ^[0-9]+$ ]] \
    && ((10#$MONGO_PORT >= 1 && 10#$MONGO_PORT <= 65535)) \
    || usage_error "MONGO_PORT must be between 1 and 65535"
  if [[ -n "$MONGO_LOCAL_PORT" ]]; then
    [[ "$MONGO_LOCAL_PORT" =~ ^[0-9]+$ ]] \
      && ((10#$MONGO_LOCAL_PORT >= 1 && 10#$MONGO_LOCAL_PORT <= 65535)) \
      || usage_error "--local-port must be between 1 and 65535"
  fi
  if [[ "$CHECK_ONLY" == "true" && "$DRY_RUN" == "true" ]]; then
    usage_error "--check-prerequisites and --dry-run cannot be combined"
  fi
  if [[ "$CHECK_ONLY" != "true" && -z "$KUBECONFIG_FILE" ]]; then
    usage_error "--kubeconfig is required"
  fi
  if [[ "$CHECK_ONLY" != "true" && "$DRY_RUN" != "true" \
    && "$AGENT_UPGRADE_PAUSED" != "true" ]]; then
    usage_error "enable Pause Agent Upgrade, then pass --agent-upgrade-paused"
  fi
}

start_log() {
  RUN_NAME="palette-mongo-backup-$RUN_ID"
  mkdir -p "$ARTIFACTS_DIR"
  chmod 700 "$ARTIFACTS_DIR"
  LOG_FILE="$ARTIFACTS_DIR/$RUN_NAME.log"
  [[ ! -e "$LOG_FILE" ]] || { fail "log already exists: $LOG_FILE"; exit 1; }
  : > "$LOG_FILE"
  chmod 600 "$LOG_FILE"
  exec 3>&1 4>&2
  exec >> "$LOG_FILE" 2>&1
  LOG_ACTIVE=true
  info "Log: $LOG_FILE"
}

verify_package() {
  local file="$1" expected="$2" actual
  [[ -f "$file" ]] || { fail "bundled package is missing: $file"; return 1; }
  actual=$(sha256_file "$file")
  [[ "$actual" == "$expected" ]] || {
    fail "checksum mismatch for ${file##*/}"
    return 1
  }
  pass "Verified bundled package: ${file##*/}"
}

print_install_instructions() {
  local os_id="" os_version=""
  if [[ "$(uname -s)" == "Linux" && -r /etc/os-release ]]; then
    os_id=$(. /etc/os-release; printf '%s' "${ID:-}")
    os_version=$(. /etc/os-release; printf '%s' "${VERSION_ID:-}")
  fi
  case "$os_id:$os_version:$(uname -m)" in
    ubuntu:24.04:x86_64)
      warn "Ubuntu 24.04 x86-64: install the bundled .deb with sudo $INSTALLER"
      ;;
    rocky:9.*:x86_64)
      warn "Rocky Linux 9 x86-64: install the bundled RHEL 9 .rpm with sudo $INSTALLER"
      ;;
    *)
      warn "No bundled package matches $(uname -s) $(uname -m)."
      warn "Install MongoDB Database Tools $TOOLS_VERSION for this OS, then rerun."
      ;;
  esac
}

check_prerequisites() {
  local command_name help_output version_output
  local missing=""

  info "Checking local prerequisites first"
  for command_name in kubectl mongodump base64 awk find grep sed sort du python3; do
    command -v "$command_name" >/dev/null 2>&1 \
      || missing="${missing}${missing:+, }$command_name"
  done
  if ! command -v sha256sum >/dev/null 2>&1 \
    && ! command -v shasum >/dev/null 2>&1; then
    missing="${missing}${missing:+, }sha256sum-or-shasum"
  fi
  if [[ -n "$missing" ]]; then
    fail "Missing commands: $missing"
    print_install_instructions
    return 1
  fi

  verify_package \
    "$SCRIPT_DIR/artifacts/packages/mongodb-database-tools-ubuntu2404-x86_64-$TOOLS_VERSION.deb" \
    "cfc40386b5c909509fd4b35a4a1f212aeaedc17a3062703d4b4b0823c2beb1b7"
  verify_package \
    "$SCRIPT_DIR/artifacts/packages/mongodb-database-tools-rhel93-x86_64-$TOOLS_VERSION.rpm" \
    "d3c341c123e29d376b36d7245c9eed5ec0ea283d839cedb6017348c27269e78f"

  version_output=$(mongodump --version 2>&1 || true)
  MONGODUMP_VERSION=$(printf '%s\n' "$version_output" \
    | sed -n 's/.*version: *\([0-9][0-9.]*\).*/\1/p' | sed -n '1p')
  help_output=$(mongodump --help 2>&1 || true)
  for command_name in --config --db; do
    printf '%s' "$help_output" | grep -q -- "$command_name" || {
      fail "mongodump $MONGODUMP_VERSION does not expose $command_name"
      return 1
    }
  done
  if printf '%s' "$help_output" | grep -q -- '--sslCAFile' \
    && printf '%s' "$help_output" | grep -q -- '--sslPEMKeyFile' \
    && printf '%s' "$help_output" | grep -q -- '--tlsInsecure'; then
    MONGODUMP_TLS_STYLE="ssl"
  elif printf '%s' "$help_output" | grep -q -- '--tlsCAFile' \
    && printf '%s' "$help_output" | grep -q -- '--tlsCertificateKeyFile' \
    && printf '%s' "$help_output" | grep -q -- '--tlsAllowInvalidCertificates'; then
    MONGODUMP_TLS_STYLE="tls"
  else
    fail "mongodump $MONGODUMP_VERSION does not expose a supported TLS option set"
    return 1
  fi
  pass "Local prerequisites are ready (mongodump $MONGODUMP_VERSION, $MONGODUMP_TLS_STYLE options)"
}

validate_kubeconfig() {
  [[ -f "$KUBECONFIG_FILE" ]] || { fail "kubeconfig not found: $KUBECONFIG_FILE"; return 1; }
  [[ -r "$KUBECONFIG_FILE" ]] || { fail "kubeconfig is not readable: $KUBECONFIG_FILE"; return 1; }
}

print_plan() {
  local plan
  plan=$(cat <<EOF
Backup plan
  Kubeconfig : $KUBECONFIG_FILE
  Namespace  : $NAMESPACE
  Query pod  : $MONGO_QUERY_POD
  Artifacts  : $ARTIFACTS_DIR

  1. Validate cluster access, required Secrets, and MongoDB pods.
  2. Detect MongoDB 6, 7, or 8 and locate the healthy primary.
  3. Export restore-critical Palette Secrets.
  4. Open a temporary TLS port-forward to the primary.
  5. Back up and verify the Palette databases with mongodump.
     hubble_archivedb is optional and produces a warning if unavailable.
  6. Write a summary, completion marker, and SHA-256 manifest.
EOF
)
  printf '%s\n' "$plan"
  [[ "$LOG_ACTIVE" == "false" ]] || printf '%s\n' "$plan" >&3
}

check_cluster_access() {
  local secret pods context
  info "Checking source-cluster prerequisites"
  kubectl_cmd cluster-info >/dev/null
  context=$(kubectl_cmd config current-context 2>/dev/null || true)
  info "Kubernetes context: ${context:-unknown}"
  kubectl_cmd get namespace "$NAMESPACE" >/dev/null
  for secret in configserversecret msgbroker-secret "$MONGO_SECRET"; do
    kubectl_cmd get secret "$secret" -n "$NAMESPACE" >/dev/null
  done
  pods=$(kubectl_cmd get pods -n "$NAMESPACE" -o name \
    | sed -n 's#^pod/\(mongo-[0-9][0-9]*\)$#\1#p')
  [[ -n "$pods" ]] || { fail "no mongo-N pods found in $NAMESPACE"; return 1; }
  printf '%s\n' "$pods" | grep -qx "$MONGO_QUERY_POD" \
    || { fail "query pod not found: $NAMESPACE/$MONGO_QUERY_POD"; return 1; }
  pass "Cluster prerequisites are ready"
}

read_password() {
  local encoded password
  encoded=$(kubectl_cmd get secret "$MONGO_SECRET" -n "$NAMESPACE" \
    -o 'jsonpath={.data.mongoRootPassword}')
  [[ -n "$encoded" ]] || { fail "mongoRootPassword is missing from $MONGO_SECRET"; return 1; }
  password=$(printf '%s' "$encoded" | decode_base64)
  [[ -n "$password" ]] || { fail "decoded MongoDB password is empty"; return 1; }
  printf '%s' "$password"
}

query_mongo_facts() {
  local password="$1" result facts database database_name major
  info "Detecting MongoDB version, databases, and primary" >&2
  result=$(kubectl_cmd exec -n "$NAMESPACE" "$MONGO_QUERY_POD" -c mongo -- \
    env OPENSSL_CONF=/dev/null mongosh --quiet \
      --port "$MONGO_PORT" --username "$MONGO_USER" --password "$password" \
      --authenticationDatabase "$AUTH_DB" --tls \
      --tlsCAFile /var/mongodb/tls/ca.crt \
      --tlsCertificateKeyFile /var/mongodb/tls/tls-combined.pem \
      --tlsAllowInvalidCertificates \
      --eval 'JSON.stringify({version:db.version(),databases:db.getSiblingDB("admin").adminCommand({listDatabases:1,nameOnly:true}).databases.map(d=>d.name),members:rs.status().members.map(m=>({name:m.name,state:m.stateStr,health:m.health}))})')

  facts=$(printf '%s' "$result" | python3 -c '
import json, sys
data = json.load(sys.stdin)
primary = next((m.get("name", "") for m in data.get("members", [])
                if m.get("state") == "PRIMARY" and m.get("health") == 1), "")
primary = primary.split(":", 1)[0].split(".", 1)[0]
print("\t".join((str(data.get("version", "")), primary,
                 ",".join(data.get("databases", [])))))
')
  IFS=$'\t' read -r MONGO_SERVER_VERSION PRIMARY_POD database <<< "$facts"
  MONGO_DATABASES="$database"
  [[ -n "$MONGO_SERVER_VERSION" && -n "$PRIMARY_POD" ]] \
    || { fail "could not identify the MongoDB version and healthy primary"; return 1; }
  major=${MONGO_SERVER_VERSION%%.*}
  case "$major" in
    6|7|8) ;;
    *)
      fail "MongoDB $MONGO_SERVER_VERSION is outside this workflow's supported 6.x, 7.x, and 8.x range"
      return 1
      ;;
  esac
  for database_name in "${DATABASES[@]}"; do
    if [[ ",$database," != *",$database_name,"* ]]; then
      if [[ "$database_name" == "$OPTIONAL_DATABASE" ]]; then
        warn "Optional database is missing: $database_name; backup will continue"
      else
        fail "required database is missing: $database_name"
        return 1
      fi
    fi
  done
  pass "MongoDB $MONGO_SERVER_VERSION detected; using mongodump ${MONGODUMP_VERSION:-unknown}"
  pass "Healthy MongoDB primary: $PRIMARY_POD"
}

create_backup_directory() {
  BACKUP_DIR="$ARTIFACTS_DIR/$RUN_NAME"
  [[ ! -e "$BACKUP_DIR" ]] || { fail "backup directory already exists: $BACKUP_DIR"; return 1; }
  mkdir -p "$BACKUP_DIR/secrets" "$BACKUP_DIR/databases"
  chmod 700 "$BACKUP_DIR"
  printf 'Backup did not complete. Review %s.\n' "$LOG_FILE" > "$BACKUP_DIR/INCOMPLETE"
  BACKUP_STARTED=true
}

export_secret() {
  local name="$1" destination="$BACKUP_DIR/secrets/$1.json"
  info "Exporting $NAMESPACE/$name"
  kubectl_cmd get secret "$name" -n "$NAMESPACE" -o json \
    | python3 -c '
import json, sys
source = json.load(sys.stdin)
clean = {
    "apiVersion": "v1",
    "kind": "Secret",
    "metadata": {"name": source["metadata"]["name"],
                 "namespace": source["metadata"]["namespace"]},
    "type": source.get("type", "Opaque"),
    "data": source.get("data", {}),
}
if "immutable" in source:
    clean["immutable"] = source["immutable"]
json.dump(clean, sys.stdout, indent=2, sort_keys=True)
print()
' > "$destination"
  chmod 600 "$destination"
}

copy_tls_file() {
  local remote="$1" local_file="$2"
  kubectl_cmd exec -n "$NAMESPACE" "$PRIMARY_POD" -c mongo -- cat "$remote" \
    > "$local_file"
  [[ -s "$local_file" ]] || { fail "MongoDB TLS file is empty: $remote"; return 1; }
  chmod 600 "$local_file"
}

prepare_transport() {
  local attempt port
  TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/palette-mongo-backup.XXXXXX")
  chmod 700 "$TEMP_DIR"
  copy_tls_file /var/mongodb/tls/ca.crt "$TEMP_DIR/ca.crt"
  copy_tls_file /var/mongodb/tls/tls-combined.pem "$TEMP_DIR/tls-combined.pem"
  port=${MONGO_LOCAL_PORT:-$(select_local_port)}
  MONGO_LOCAL_PORT="$port"
  info "Opening 127.0.0.1:$port to $NAMESPACE/$PRIMARY_POD:$MONGO_PORT"
  kubectl_cmd port-forward -n "$NAMESPACE" --address 127.0.0.1 \
    "pod/$PRIMARY_POD" "$port:$MONGO_PORT" > "$TEMP_DIR/port-forward.log" 2>&1 &
  PORT_FORWARD_PID=$!
  for attempt in {1..100}; do
    grep -q "Forwarding from 127.0.0.1:$port" "$TEMP_DIR/port-forward.log" && return 0
    kill -0 "$PORT_FORWARD_PID" 2>/dev/null || break
    sleep 0.1
  done
  fail "could not establish the MongoDB port-forward"
  return 1
}

run_mongodump() {
  local password="$1" database
  local -a tls_options
  printf '%s' "$password" | python3 -c '
import json, sys
json.dump({"password": sys.stdin.read()}, sys.stdout)
' > "$TEMP_DIR/mongodump-config.yml"
  chmod 600 "$TEMP_DIR/mongodump-config.yml"

  if [[ "$MONGODUMP_TLS_STYLE" == "ssl" ]]; then
    tls_options=(
      --ssl
      --sslCAFile="$TEMP_DIR/ca.crt"
      --sslPEMKeyFile="$TEMP_DIR/tls-combined.pem"
      --tlsInsecure
    )
  else
    tls_options=(
      --tls
      --tlsCAFile="$TEMP_DIR/ca.crt"
      --tlsCertificateKeyFile="$TEMP_DIR/tls-combined.pem"
      --tlsAllowInvalidCertificates
    )
  fi

  for database in "${DATABASES[@]}"; do
    if [[ "$database" == "$OPTIONAL_DATABASE" \
      && ",$MONGO_DATABASES," != *",$database,"* ]]; then
      continue
    fi

    info "Backing up $database"
    if ! OPENSSL_CONF=/dev/null mongodump \
        --config="$TEMP_DIR/mongodump-config.yml" \
        --host=127.0.0.1 --port="$MONGO_LOCAL_PORT" \
        --username="$MONGO_USER" --authenticationDatabase="$AUTH_DB" \
        "${tls_options[@]}" \
        --numParallelCollections=1 --gzip \
        --db="$database" \
        --out="$BACKUP_DIR/databases"; then
      if [[ "$database" == "$OPTIONAL_DATABASE" ]]; then
        warn "mongodump failed for optional database $database; backup will continue"
        rm -rf -- "$BACKUP_DIR/databases/$database"
        continue
      fi
      fail "mongodump failed for required database $database"
      return 1
    fi

    if [[ ! -d "$BACKUP_DIR/databases/$database" ]]; then
      if [[ "$database" == "$OPTIONAL_DATABASE" ]]; then
        warn "mongodump did not create optional database $database; backup will continue"
        continue
      fi
      fail "mongodump did not create $database"
      return 1
    fi
    if [[ -z "$(find "$BACKUP_DIR/databases/$database" -type f -name '*.bson.gz' -print -quit)" ]]; then
      if [[ "$database" == "$OPTIONAL_DATABASE" ]]; then
        warn "mongodump created no compressed BSON files for optional database $database; backup will continue"
        rm -rf -- "$BACKUP_DIR/databases/$database"
        continue
      fi
      fail "mongodump created no compressed BSON files for $database"
      return 1
    fi
    pass "Verified backup data for $database"
  done
}

cleanup_transport() {
  if [[ -n "$PORT_FORWARD_PID" ]]; then
    kill "$PORT_FORWARD_PID" 2>/dev/null || true
    wait "$PORT_FORWARD_PID" 2>/dev/null || true
    PORT_FORWARD_PID=""
  fi
  if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
    rm -f "$TEMP_DIR/ca.crt" "$TEMP_DIR/tls-combined.pem" \
      "$TEMP_DIR/mongodump-config.yml" "$TEMP_DIR/port-forward.log"
    rmdir "$TEMP_DIR" 2>/dev/null || true
    TEMP_DIR=""
  fi
}

write_summary() {
  local database context
  context=$(kubectl_cmd config current-context 2>/dev/null || true)
  {
    printf 'Palette EC MongoDB Backup v2\n'
    printf 'Completed (UTC): %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf 'Kubernetes context: %s\n' "${context:-unknown}"
    printf 'Namespace: %s\n' "$NAMESPACE"
    printf 'MongoDB server: %s\n' "$MONGO_SERVER_VERSION"
    printf 'MongoDB primary: %s\n' "$PRIMARY_POD"
    printf 'mongodump: %s\n' "$MONGODUMP_VERSION"
    printf 'Log: %s\n\n' "$LOG_FILE"
    printf 'Databases:\n'
    for database in "${DATABASES[@]}"; do
      if [[ -d "$BACKUP_DIR/databases/$database" ]] \
        && [[ -n "$(find "$BACKUP_DIR/databases/$database" -type f -name '*.bson.gz' -print -quit)" ]]; then
        printf '  - %s: %s\n' "$database" \
          "$(du -sh "$BACKUP_DIR/databases/$database" | awk '{print $1}')"
      else
        printf '  - %s: not backed up (optional)\n' "$database"
      fi
    done
    printf '\nRestore-critical Secrets:\n'
    printf '  - secrets/configserversecret.json\n'
    printf '  - secrets/msgbroker-secret.json\n'
  } > "$BACKUP_DIR/backup-summary.txt"
  chmod 600 "$BACKUP_DIR/backup-summary.txt"
}

write_checksums() {
  local file relative
  : > "$BACKUP_DIR/SHA256SUMS"
  while IFS= read -r file; do
    relative=${file#"$BACKUP_DIR/"}
    if command -v sha256sum >/dev/null 2>&1; then
      (cd "$BACKUP_DIR" && sha256sum "$relative") >> "$BACKUP_DIR/SHA256SUMS"
    else
      (cd "$BACKUP_DIR" && shasum -a 256 "$relative") >> "$BACKUP_DIR/SHA256SUMS"
    fi
  done < <(find "$BACKUP_DIR" -type f ! -name SHA256SUMS ! -name INCOMPLETE \
    ! -name COMPLETED -print | LC_ALL=C sort)
  chmod 600 "$BACKUP_DIR/SHA256SUMS"
}

on_exit() {
  local status=$?
  trap - EXIT
  set +e
  if ((status != 0)) && [[ -n "$TEMP_DIR" && -f "$TEMP_DIR/port-forward.log" \
    && "$BACKUP_STARTED" == "true" ]]; then
    cp "$TEMP_DIR/port-forward.log" "$BACKUP_DIR/port-forward.log"
    chmod 600 "$BACKUP_DIR/port-forward.log"
  fi
  cleanup_transport
  if ((status != 0)); then
    fail "Command did not complete. Log: ${LOG_FILE:-not created}"
    [[ "$BACKUP_STARTED" == "false" ]] || fail "Partial artifacts: $BACKUP_DIR"
  fi
  exit "$status"
}

main() {
  local password
  (($#)) || { usage; return 0; }
  parse_args "$@"
  validate_args
  start_log
  trap on_exit EXIT

  check_prerequisites
  if [[ "$CHECK_ONLY" == "true" ]]; then
    pass "Prerequisite check completed"
    return 0
  fi

  validate_kubeconfig
  if [[ "$DRY_RUN" == "true" ]]; then
    print_plan
    return 0
  fi

  check_cluster_access
  password=$(read_password)
  query_mongo_facts "$password"
  create_backup_directory

  info "Exporting restore-critical Secrets"
  export_secret configserversecret
  export_secret msgbroker-secret

  prepare_transport
  run_mongodump "$password"
  unset password
  cleanup_transport

  write_summary
  write_checksums
  rm -f "$BACKUP_DIR/INCOMPLETE"
  printf 'Backup completed successfully. Verify SHA256SUMS before transfer or restore.\n' \
    > "$BACKUP_DIR/COMPLETED"
  chmod 600 "$BACKUP_DIR/COMPLETED"
  BACKUP_STARTED=false

  pass "Backup completed: $BACKUP_DIR"
  artifact_security_warning
}

main "$@"
