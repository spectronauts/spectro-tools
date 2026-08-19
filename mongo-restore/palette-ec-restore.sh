#!/usr/bin/env bash
# Compiled by Jason Cuff - Spectro Cloud
# Restores the output produced by palette-ec-backup.sh to a Palette EC target.

set -Eeuo pipefail

readonly SCRIPT_NAME="${0##*/}"
readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly COMMON_CONFIG="${SCRIPT_DIR}/../config/common-config.sh"
readonly COMMON_FUNCTIONS="${SCRIPT_DIR}/../config/common-functions.sh"
# shellcheck source=../config/common-config.sh
source "${COMMON_CONFIG}"
# shellcheck source=../config/common-functions.sh
source "${COMMON_FUNCTIONS}"
readonly -a REQUIRED_DATABASES=(hubbledb hubble_timeseriesdb)
readonly OPTIONAL_DATABASE="hubble_archivedb"
readonly -a RESTORE_SECRET_FILES=(configserversecret.json msgbroker-secret.json)

KUBECONFIG_FILE=""
BACKUP_DIR=""
BACKUP_DATABASE_DIR=""
LOG_DIR="${LOG_DIR:-${SCRIPT_DIR}/logs}"
NAMESPACE="${NAMESPACE:-hubble-system}"
MONGO_PORT="${MONGO_PORT:-27017}"
MONGO_USER="${MONGO_USER:-root}"
AUTH_DB="${AUTH_DB:-admin}"
MONGO_SECRET="${MONGO_SECRET:-spectromongosecret}"
MONGO_QUERY_POD="${MONGO_QUERY_POD:-mongo-0}"
MONGO_LOCAL_PORT="${MONGO_LOCAL_PORT:-}"
AGENT_UPGRADE_PAUSED=false
APPLICATION_WRITERS_STOPPED=false
TARGET_BACKUP_CONFIRMED=false
RESTORE_SECRETS=false
PLAN_ONLY=false
DRY_RUN=false
CONFIRM_TARGET=""
TARGET_CONTEXT=""
TARGET_ID=""
REMOTE_POD=""
TLS_TEMP_DIR=""
PORT_FORWARD_PID=""
LOCAL_MONGO_PORT=""
MONGORESTORE_TLS_STYLE=""
MONGORESTORE_VERSION=""
LOG_FILE=""
RESTORE_STARTED=false
RESTORE_SUCCEEDED=false
RESTORE_DATABASES=()

if [[ -t 1 ]]; then
    readonly RED=$'\033[0;31m'
    readonly GREEN=$'\033[0;32m'
    readonly YELLOW=$'\033[1;33m'
    readonly BLUE=$'\033[0;34m'
    readonly NC=$'\033[0m'
else
    readonly RED=""
    readonly GREEN=""
    readonly YELLOW=""
    readonly BLUE=""
    readonly NC=""
fi

log_info() {
    printf '%s[INFO]%s %s\n' "$BLUE" "$NC" "$*"
    [[ -z "${LOG_FILE:-}" ]] || printf '[INFO] %s\n' "$*" >>"$LOG_FILE"
}

log_success() {
    printf '%s[SUCCESS]%s %s\n' "$GREEN" "$NC" "$*"
    [[ -z "${LOG_FILE:-}" ]] || printf '[SUCCESS] %s\n' "$*" >>"$LOG_FILE"
}

log_warning() {
    printf '%s[WARNING]%s %s\n' "$YELLOW" "$NC" "$*" >&2
    [[ -z "${LOG_FILE:-}" ]] || printf '[WARNING] %s\n' "$*" >>"$LOG_FILE"
}

log_error() {
    printf '%s[ERROR]%s %s\n' "$RED" "$NC" "$*" >&2
    [[ -z "${LOG_FILE:-}" ]] || printf '[ERROR] %s\n' "$*" >>"$LOG_FILE"
}

usage() {
    cat <<EOF
Palette EC MongoDB restore

Usage:
  $SCRIPT_NAME --kubeconfig FILE --backup-dir DIR [MODE] [OPTIONS]

Required:
  --kubeconfig FILE                  Target cluster kubeconfig
  --backup-dir DIR                   Completed palette-ec-backup directory

Modes:
  --plan                             Print the workflow without connecting
  --dry-run                          Verify checksums, connect to the target,
                                     and run mongorestore --dryRun

Required for a live restore:
  --agent-upgrade-paused             Confirm Pause Agent Upgrade is enabled
  --application-writers-stopped      Confirm Palette database writers are stopped
  --target-backup-confirmed          Confirm a target rollback point exists

Options:
  --restore-secrets                  Apply configserversecret and msgbroker-secret
                                     after the databases restore successfully
  --confirm-target VALUE             Non-interactive exact confirmation. VALUE must
                                     equal "RESTORE <context>/<namespace>".
  --namespace NAME                   Palette namespace (default: hubble-system)
  --log-dir DIR                      Restore logs (default: $SCRIPT_DIR/logs)
  -h, --help                         Show this help

Environment overrides:
  LOG_DIR, NAMESPACE, MONGO_PORT, MONGO_USER, AUTH_DB, MONGO_SECRET,
  MONGO_QUERY_POD, MONGO_LOCAL_PORT

The script does not stop or restart Palette workloads. A failed live restore
leaves application writers stopped for operator-directed recovery.
EOF
}

parse_arguments() {
    while (($# > 0)); do
        case "$1" in
            --kubeconfig)
                require_value "$1" "${2:-}"
                KUBECONFIG_FILE="$2"
                shift 2
                ;;
            --backup-dir)
                require_value "$1" "${2:-}"
                BACKUP_DIR="$2"
                shift 2
                ;;
            --namespace)
                require_value "$1" "${2:-}"
                NAMESPACE="$2"
                shift 2
                ;;
            --log-dir)
                require_value "$1" "${2:-}"
                LOG_DIR="$2"
                shift 2
                ;;
            --confirm-target)
                require_value "$1" "${2:-}"
                CONFIRM_TARGET="$2"
                shift 2
                ;;
            --agent-upgrade-paused)
                AGENT_UPGRADE_PAUSED=true
                shift
                ;;
            --application-writers-stopped)
                APPLICATION_WRITERS_STOPPED=true
                shift
                ;;
            --target-backup-confirmed)
                TARGET_BACKUP_CONFIRMED=true
                shift
                ;;
            --restore-secrets)
                RESTORE_SECRETS=true
                shift
                ;;
            --plan)
                PLAN_ONLY=true
                shift
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                usage >&2
                exit 2
                ;;
        esac
    done
}

validate_local_inputs() {
    if [[ -z "$KUBECONFIG_FILE" ]]; then
        log_error "--kubeconfig is required"
        exit 2
    fi
    if [[ ! -f "$KUBECONFIG_FILE" || ! -r "$KUBECONFIG_FILE" ]]; then
        log_error "Kubeconfig is missing or unreadable: $KUBECONFIG_FILE"
        exit 2
    fi
    if [[ -z "$BACKUP_DIR" ]]; then
        log_error "--backup-dir is required"
        exit 2
    fi
    if [[ ! -d "$BACKUP_DIR" || ! -r "$BACKUP_DIR" ]]; then
        log_error "Backup directory is missing or unreadable: $BACKUP_DIR"
        exit 2
    fi
    if [[ "$PLAN_ONLY" == true && "$DRY_RUN" == true ]]; then
        log_error "--plan and --dry-run are mutually exclusive"
        exit 2
    fi
    if ((${#NAMESPACE} > 63)) ||
        [[ ! "$NAMESPACE" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]]; then
        log_error "Invalid Kubernetes namespace: $NAMESPACE"
        exit 2
    fi
    validate_port MONGO_PORT "$MONGO_PORT"
    if [[ -n "$MONGO_LOCAL_PORT" ]]; then
        validate_port MONGO_LOCAL_PORT "$MONGO_LOCAL_PORT"
    fi

    BACKUP_DIR="$(cd "$BACKUP_DIR" && pwd)"
    KUBECONFIG_FILE="$(cd "$(dirname "$KUBECONFIG_FILE")" && pwd)/$(basename "$KUBECONFIG_FILE")"

    if [[ "$PLAN_ONLY" != true && "$DRY_RUN" != true ]]; then
        if [[ "$AGENT_UPGRADE_PAUSED" != true ]]; then
            log_error "Live restore requires --agent-upgrade-paused"
            exit 2
        fi
        if [[ "$APPLICATION_WRITERS_STOPPED" != true ]]; then
            log_error "Live restore requires --application-writers-stopped"
            exit 2
        fi
        if [[ "$TARGET_BACKUP_CONFIRMED" != true ]]; then
            log_error "Live restore requires --target-backup-confirmed"
            exit 2
        fi
    fi
}

print_plan() {
    cat <<EOF
Palette EC restore plan
  Kubeconfig:      $KUBECONFIG_FILE
  Namespace:       $NAMESPACE
  Backup:          $BACKUP_DIR
  Restore secrets: $RESTORE_SECRETS

  1. Require COMPLETED, reject INCOMPLETE, and verify SHA256SUMS.
  2. Validate hubbledb and hubble_timeseriesdb beneath databases/.
     Include databases/hubble_archivedb only when it is present and valid.
  3. Verify target access and identify the exact Kubernetes context.
  4. Read the target MongoDB credential without printing it.
  5. Discover the healthy MongoDB primary.
  6. Copy target TLS material and open a loopback port-forward.
  7. Run mongorestore --dryRun for the databases selected from the backup.
  8. Require exact target confirmation for a live restore.
  9. Drop and restore only the databases selected from the backup.
 10. Optionally apply the two saved application secrets.
 11. Validate database collection counts and retain a restore log.

The script never stops or restarts Palette application workloads.
EOF
}

start_log() {
    local timestamp
    timestamp="$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$LOG_DIR"
    chmod 700 "$LOG_DIR"
    LOG_FILE="$LOG_DIR/restore-${timestamp}.log"
    touch "$LOG_FILE"
    chmod 600 "$LOG_FILE"
    log_info "Restore log: $LOG_FILE"
}

validate_manifest_paths() {
    python3 - "$BACKUP_DIR" "$BACKUP_DIR/SHA256SUMS" <<'PY'
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1]).resolve()
manifest = pathlib.Path(sys.argv[2])
line_pattern = re.compile(r"^[0-9a-fA-F]{64} [ *](.+)$")

for number, raw_line in enumerate(manifest.read_text().splitlines(), 1):
    match = line_pattern.match(raw_line)
    if not match:
        raise SystemExit(f"invalid SHA256SUMS line {number}")
    relative = pathlib.Path(match.group(1))
    if relative.is_absolute():
        raise SystemExit(f"absolute path in SHA256SUMS line {number}")
    resolved = (root / relative).resolve()
    try:
        resolved.relative_to(root)
    except ValueError:
        raise SystemExit(f"path escapes backup directory in SHA256SUMS line {number}")
PY
}

verify_backup() {
    local database
    [[ -f "$BACKUP_DIR/COMPLETED" ]] || {
        log_error "Backup is missing COMPLETED: $BACKUP_DIR"
        return 1
    }
    [[ ! -e "$BACKUP_DIR/INCOMPLETE" ]] || {
        log_error "Refusing an incomplete backup: $BACKUP_DIR/INCOMPLETE"
        return 1
    }
    [[ -s "$BACKUP_DIR/SHA256SUMS" ]] || {
        log_error "Backup is missing SHA256SUMS"
        return 1
    }
    validate_manifest_paths || {
        log_error "SHA256SUMS contains an invalid or unsafe path"
        return 1
    }

    log_info "Verifying backup integrity..."
    if command -v sha256sum >/dev/null 2>&1; then
        (cd "$BACKUP_DIR" && sha256sum --check SHA256SUMS)
    else
        (cd "$BACKUP_DIR" && shasum -a 256 --check SHA256SUMS)
    fi

    BACKUP_DATABASE_DIR="$BACKUP_DIR/databases"
    [[ -d "$BACKUP_DATABASE_DIR" ]] || {
        log_error "Backup is missing the databases directory: $BACKUP_DATABASE_DIR"
        return 1
    }

    RESTORE_DATABASES=()
    for database in "${REQUIRED_DATABASES[@]}"; do
        [[ -d "$BACKUP_DATABASE_DIR/$database" ]] || {
            log_error "Required backup database directory is missing: databases/$database"
            return 1
        }
        [[ -n "$(find "$BACKUP_DATABASE_DIR/$database" -type f -name '*.bson.gz' -print -quit)" ]] || {
            log_error "No compressed BSON files found for databases/$database"
            return 1
        }
        RESTORE_DATABASES+=("$database")
    done

    if [[ -d "$BACKUP_DATABASE_DIR/$OPTIONAL_DATABASE" ]]; then
        [[ -n "$(find "$BACKUP_DATABASE_DIR/$OPTIONAL_DATABASE" -type f -name '*.bson.gz' -print -quit)" ]] || {
            log_error "Optional database directory exists but has no compressed BSON files: databases/$OPTIONAL_DATABASE"
            return 1
        }
        RESTORE_DATABASES+=("$OPTIONAL_DATABASE")
    else
        log_warning "Optional database is not present in this backup: $OPTIONAL_DATABASE"
        log_warning "The target $OPTIONAL_DATABASE database will not be dropped or restored."
    fi

    if [[ "$RESTORE_SECRETS" == true ]]; then
        local secret_file secret_name
        for secret_file in "${RESTORE_SECRET_FILES[@]}"; do
            [[ -s "$BACKUP_DIR/secrets/$secret_file" ]] || {
                log_error "Restore secret is missing: secrets/$secret_file"
                return 1
            }
            secret_name="${secret_file%.json}"
            if ! python3 - "$BACKUP_DIR/secrets/$secret_file" "$secret_name" "$NAMESPACE" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
expected_name = sys.argv[2]
expected_namespace = sys.argv[3]

try:
    resource = json.loads(path.read_text())
except (OSError, json.JSONDecodeError) as error:
    raise SystemExit(f"invalid Secret JSON in {path.name}: {error}")

if not isinstance(resource, dict):
    raise SystemExit(f"{path.name} does not contain a Kubernetes resource object")
metadata = resource.get("metadata")
if resource.get("apiVersion") != "v1" or resource.get("kind") != "Secret":
    raise SystemExit(f"{path.name} is not a v1 Secret")
if not isinstance(metadata, dict) or metadata.get("name") != expected_name:
    raise SystemExit(f"{path.name} does not describe Secret {expected_name}")
if metadata.get("namespace") != expected_namespace:
    raise SystemExit(
        f"{path.name} targets namespace {metadata.get('namespace')!r}, "
        f"not {expected_namespace!r}"
    )
if not isinstance(resource.get("data"), dict):
    raise SystemExit(f"{path.name} does not contain a Secret data object")
PY
            then
                log_error "Restore secret is invalid for target namespace $NAMESPACE: secrets/$secret_file"
                return 1
            fi
        done
    fi
    log_info "Backup databases selected for restore: ${RESTORE_DATABASES[*]}"
    log_success "Backup integrity and structure verified."
}

detect_mongorestore_options() {
    local help_output
    local version_output
    help_output="$(mongorestore --help 2>&1 || true)"
    version_output="$(mongorestore --version 2>&1 || true)"
    MONGORESTORE_VERSION="${version_output%%$'\n'*}"

    if grep -q -- '--tlsCAFile' <<<"$help_output"; then
        MONGORESTORE_TLS_STYLE="tls"
    elif grep -q -- '--sslCAFile' <<<"$help_output"; then
        MONGORESTORE_TLS_STYLE="ssl"
    else
        log_error "Installed mongorestore does not expose supported TLS/SSL options"
        return 1
    fi

    local required_option
    for required_option in --config --dryRun --preserveUUID --stopOnError; do
        if ! grep -q -- "$required_option" <<<"$help_output"; then
            log_error "Installed mongorestore does not support $required_option"
            return 1
        fi
    done
    log_info "Using ${MONGORESTORE_VERSION:-mongorestore} with $MONGORESTORE_TLS_STYLE options"
}

preflight_cluster() {
    local command_name
    for command_name in kubectl mongorestore base64 python3 awk find grep sed sort tee; do
        require_command "$command_name"
    done
    if ! command -v sha256sum >/dev/null 2>&1 &&
        ! command -v shasum >/dev/null 2>&1; then
        log_error "Required checksum command not found: install sha256sum or shasum"
        return 1
    fi
    detect_mongorestore_options

    log_info "Checking access to the target cluster..."
    kubectl_cmd cluster-info >/dev/null
    TARGET_CONTEXT="$(kubectl_cmd config current-context 2>/dev/null || true)"
    [[ -n "$TARGET_CONTEXT" ]] || {
        log_error "Could not determine the target Kubernetes context"
        return 1
    }
    TARGET_ID="$TARGET_CONTEXT/$NAMESPACE"
    log_info "Target identity: $TARGET_ID"

    if ! kubectl_cmd get secret "$MONGO_SECRET" -n "$NAMESPACE" >/dev/null; then
        log_error "Required target secret not found: $NAMESPACE/$MONGO_SECRET"
        return 1
    fi

    local pods
    pods="$(kubectl_cmd get pods -n "$NAMESPACE" -o name |
        sed -n 's#^pod/\(mongo-[0-9][0-9]*\)$#\1#p')"
    [[ -n "$pods" ]] || {
        log_error "No mongo-N pods found in namespace $NAMESPACE"
        return 1
    }
    grep -qx "$MONGO_QUERY_POD" <<<"$pods" || {
        log_error "MongoDB query pod not found: $NAMESPACE/$MONGO_QUERY_POD"
        return 1
    }

    if [[ "$RESTORE_SECRETS" == true ]]; then
        local secret_file
        for secret_file in "${RESTORE_SECRET_FILES[@]}"; do
            log_info "Server-validating secret restore: $secret_file"
            kubectl_cmd apply --dry-run=server \
                -f "$BACKUP_DIR/secrets/$secret_file" >/dev/null
        done
    fi
}

read_mongo_root_password() {
    local encoded_password
    encoded_password="$(kubectl_cmd get secret "$MONGO_SECRET" -n "$NAMESPACE" \
        -o 'jsonpath={.data.mongoRootPassword}')"
    [[ -n "$encoded_password" ]] || {
        log_error "mongoRootPassword is missing from $NAMESPACE/$MONGO_SECRET"
        return 1
    }

    local password
    password="$(printf '%s' "$encoded_password" | decode_base64)" || {
        log_error "Could not decode mongoRootPassword"
        return 1
    }
    [[ -n "$password" ]] || {
        log_error "Decoded mongoRootPassword is empty"
        return 1
    }
    printf '%s' "$password"
}

mongo_primary_from_status() {
    python3 -c 'import json, re, sys
status = sys.stdin.read()

try:
    members = json.loads(status)
    primary = next((
        member.get("name", "")
        for member in members
        if member.get("state") == "PRIMARY" and member.get("health") == 1
    ), "")
except (json.JSONDecodeError, TypeError):
    primary = ""
    for member in re.findall(r"\{(.*?)\}", status, re.DOTALL):
        state = re.search(r"""(?:^|,)\s*state\s*:\s*([\"'\''])PRIMARY\1""", member)
        health = re.search(r"(?:^|,)\s*health\s*:\s*1(?:\s*,|\s*$)", member)
        name = re.search(r"""(?:^|,)\s*name\s*:\s*([\"'\''])(.*?)\1""", member)
        if state and health and name:
            primary = name.group(2)
            break

print(primary.split(":", 1)[0].split(".", 1)[0])'
}

run_remote_mongosh() {
    local password="$1"
    local javascript="$2"
    printf '%s\n' "$password" |
        kubectl_cmd exec -i -n "$NAMESPACE" "$REMOTE_POD" -c mongo -- \
            sh -c '
                IFS= read -r mongo_password
                exec env OPENSSL_CONF=/dev/null mongosh \
                    --port "$1" \
                    -u "$2" \
                    -p "$mongo_password" \
                    --authenticationDatabase "$3" \
                    --tls \
                    --tlsCAFile /var/mongodb/tls/ca.crt \
                    --tlsCertificateKeyFile /var/mongodb/tls/tls-combined.pem \
                    --tlsAllowInvalidHostnames \
                    --quiet \
                    --eval "$4"
            ' palette-restore \
            "$MONGO_PORT" "$MONGO_USER" "$AUTH_DB" "$javascript"
}

discover_primary() {
    local password="$1"
    local primary
    local result

    log_info "Querying MongoDB replica-set status from $MONGO_QUERY_POD..." >&2
    local previous_remote_pod="$REMOTE_POD"
    REMOTE_POD="$MONGO_QUERY_POD"
    result="$(
        run_remote_mongosh "$password" \
            "rs.status().members.map(m => ({name: m.name, state: m.stateStr, health: m.health, optime: m.optimeDate}))"
    )" || {
        REMOTE_POD="$previous_remote_pod"
        log_error "Authenticated TLS replica-set status query failed"
        return 1
    }
    REMOTE_POD="$previous_remote_pod"

    result="${result//$'\r'/}"
    log_info "MongoDB replica-set members:" >&2
    printf '%s\n' "$result" >&2
    primary="$(printf '%s' "$result" | mongo_primary_from_status)"
    [[ -n "$primary" ]] || {
        log_error "No healthy MongoDB primary found"
        return 1
    }
    printf '%s' "$primary"
}

cleanup_local_transport() {
    if [[ -n "$PORT_FORWARD_PID" ]]; then
        log_info "Closing MongoDB port-forward..."
        kill "$PORT_FORWARD_PID" 2>/dev/null || true
        wait "$PORT_FORWARD_PID" 2>/dev/null || true
        PORT_FORWARD_PID=""
    fi

    if [[ -n "$TLS_TEMP_DIR" && -d "$TLS_TEMP_DIR" ]]; then
        rm -f -- \
            "$TLS_TEMP_DIR/ca.crt" \
            "$TLS_TEMP_DIR/tls-combined.pem" \
            "$TLS_TEMP_DIR/mongorestore.yml" \
            "$TLS_TEMP_DIR/port-forward.log"
        rmdir "$TLS_TEMP_DIR" 2>/dev/null || true
        TLS_TEMP_DIR=""
    fi
}

on_exit() {
    local status=$?
    if ((status != 0)) &&
        [[ -n "$TLS_TEMP_DIR" && -f "$TLS_TEMP_DIR/port-forward.log" &&
        -n "$LOG_DIR" ]]; then
        cp "$TLS_TEMP_DIR/port-forward.log" \
            "$LOG_DIR/port-forward-failed.log" 2>/dev/null || true
        chmod 600 "$LOG_DIR/port-forward-failed.log" 2>/dev/null || true
    fi
    cleanup_local_transport
    if ((status != 0)); then
        if [[ "$RESTORE_STARTED" == true ]]; then
            log_error "Restore failed after target databases were dropped."
            log_error "Keep Palette writers stopped and rerun from a clean target state."
        else
            log_error "Restore validation failed before database replacement."
        fi
        [[ -z "$LOG_FILE" ]] || log_error "Review the restore log: $LOG_FILE"
    fi
    return "$status"
}

copy_mongo_tls_file() {
    local remote_file="$1"
    local local_file="$2"
    kubectl_cmd exec -n "$NAMESPACE" "$REMOTE_POD" -c mongo -- \
        cat "$remote_file" >"$local_file" || {
        rm -f -- "$local_file"
        log_error "Could not read MongoDB TLS file: $remote_file"
        return 1
    }
    [[ -s "$local_file" ]] || {
        rm -f -- "$local_file"
        log_error "MongoDB TLS file is empty: $remote_file"
        return 1
    }
    chmod 600 "$local_file"
}

write_mongorestore_config() {
    local password="$1"
    printf '%s' "$password" |
        python3 -c 'import json, sys
print("password: " + json.dumps(sys.stdin.read()))' \
            >"$TLS_TEMP_DIR/mongorestore.yml"
    chmod 600 "$TLS_TEMP_DIR/mongorestore.yml"
}

prepare_local_transport() {
    local temp_root="${TMPDIR:-/tmp}"
    local attempt
    TLS_TEMP_DIR="$(mktemp -d "${temp_root%/}/palette-ec-restore-tls.XXXXXX")"
    chmod 700 "$TLS_TEMP_DIR"

    log_info "Copying temporary MongoDB TLS files from $REMOTE_POD..."
    copy_mongo_tls_file /var/mongodb/tls/ca.crt "$TLS_TEMP_DIR/ca.crt"
    copy_mongo_tls_file \
        /var/mongodb/tls/tls-combined.pem \
        "$TLS_TEMP_DIR/tls-combined.pem"

    if [[ -n "$MONGO_LOCAL_PORT" ]]; then
        LOCAL_MONGO_PORT="$MONGO_LOCAL_PORT"
    else
        LOCAL_MONGO_PORT="$(select_local_port)"
    fi
    log_info "Opening port-forward to $REMOTE_POD on 127.0.0.1:$LOCAL_MONGO_PORT..."
    kubectl_cmd port-forward -n "$NAMESPACE" --address 127.0.0.1 \
        "pod/$REMOTE_POD" "$LOCAL_MONGO_PORT:$MONGO_PORT" \
        >"$TLS_TEMP_DIR/port-forward.log" 2>&1 &
    PORT_FORWARD_PID=$!

    for attempt in {1..50}; do
        if grep -q "Forwarding from 127.0.0.1:$LOCAL_MONGO_PORT" \
            "$TLS_TEMP_DIR/port-forward.log"; then
            return 0
        fi
        if ! kill -0 "$PORT_FORWARD_PID" 2>/dev/null; then
            break
        fi
        sleep 0.1
    done
    log_error "Could not establish the MongoDB port-forward"
    sed 's/^/  /' "$TLS_TEMP_DIR/port-forward.log" >&2
    return 1
}

run_mongorestore() {
    local mode="$1"
    local database
    local -a args
    args=(
        --config "$TLS_TEMP_DIR/mongorestore.yml"
        --host 127.0.0.1
        --port "$LOCAL_MONGO_PORT"
        --username "$MONGO_USER"
        --authenticationDatabase "$AUTH_DB"
    )
    if [[ "$MONGORESTORE_TLS_STYLE" == "tls" ]]; then
        args+=(
            --tls
            --tlsCAFile "$TLS_TEMP_DIR/ca.crt"
            --tlsCertificateKeyFile "$TLS_TEMP_DIR/tls-combined.pem"
            --tlsAllowInvalidHostnames
        )
    else
        args+=(
            --ssl
            --sslCAFile "$TLS_TEMP_DIR/ca.crt"
            --sslPEMKeyFile "$TLS_TEMP_DIR/tls-combined.pem"
            --sslAllowInvalidHostnames
        )
    fi
    args+=(
        --gzip
        --numParallelCollections=1
    )
    for database in "${RESTORE_DATABASES[@]}"; do
        args+=("--nsInclude=${database}.*")
    done
    if [[ "$mode" == "dry-run" ]]; then
        args+=(--dryRun --verbose)
        log_info "Running mongorestore validation dry run..."
    else
        args+=(
            --drop
            --preserveUUID
            --stopOnError
            '--writeConcern={w:"majority"}'
        )
        log_info "Restoring Palette databases: ${RESTORE_DATABASES[*]}"
    fi
    args+=("$BACKUP_DATABASE_DIR")
    local restore_status
    set +e
    OPENSSL_CONF=/dev/null mongorestore "${args[@]}" 2>&1 |
        tee -a "$LOG_FILE"
    restore_status=${PIPESTATUS[0]}
    set -e
    return "$restore_status"
}

confirm_exact_target() {
    local expected="RESTORE $TARGET_ID"
    local response="$CONFIRM_TARGET"
    if [[ -z "$response" ]]; then
        [[ -t 0 ]] || {
            log_error "Live restore requires --confirm-target \"$expected\" in non-interactive use"
            return 1
        }
        printf '\nThis permanently replaces these Palette databases on %s:\n  %s\n' \
            "$TARGET_ID" "${RESTORE_DATABASES[*]}"
        read -r -p "Type exactly \"$expected\" to continue: " response
    fi
    [[ "$response" == "$expected" ]] || {
        log_error "Target confirmation did not exactly match: $expected"
        return 1
    }
    log_info "Exact target confirmation accepted."
}

ensure_primary_unchanged() {
    local password="$1"
    local current_primary
    current_primary="$(discover_primary "$password")"
    [[ "$current_primary" == "$REMOTE_POD" ]] || {
        log_error "MongoDB primary changed from $REMOTE_POD to $current_primary"
        log_error "Rerun the restore so the port-forward targets the current primary"
        return 1
    }
}

drop_target_databases() {
    local password="$1"
    local database_javascript database_json
    database_json="$(python3 - "${RESTORE_DATABASES[@]}" <<'PY'
import json
import sys
print(json.dumps(sys.argv[1:]))
PY
)"
    database_javascript="
const databases = ${database_json};
for (const database of databases) {
  print(\`Dropping \${database}\`);
  const result = db.getSiblingDB(database).dropDatabase();
  if (!result.ok) {
    throw new Error(\`Failed to drop \${database}: \${tojson(result)}\`);
  }
}"
    log_warning "Dropping target Palette databases: ${RESTORE_DATABASES[*]}"
    RESTORE_STARTED=true
    run_remote_mongosh "$password" "$database_javascript"
}

apply_restore_secrets() {
    [[ "$RESTORE_SECRETS" == true ]] || {
        log_info "Application secret restoration was not requested."
        return
    }
    local secret_file
    for secret_file in "${RESTORE_SECRET_FILES[@]}"; do
        log_info "Applying restored application secret: $secret_file"
        kubectl_cmd apply -f "$BACKUP_DIR/secrets/$secret_file"
    done
}

validate_restored_databases() {
    local password="$1"
    local validation_javascript database_json
    database_json="$(python3 - "${RESTORE_DATABASES[@]}" <<'PY'
import json
import sys
print(json.dumps(sys.argv[1:]))
PY
)"
    validation_javascript="
const databases = ${database_json};
for (const database of databases) {
  const names = db.getSiblingDB(database).getCollectionNames();
  if (names.length === 0) {
    throw new Error(\`\${database} has no collections after restore\`);
  }
  print(\`\${database}: \${names.length} collections\`);
}"
    log_info "Validating restored database collection counts..."
    run_remote_mongosh "$password" "$validation_javascript"
}

main() {
    parse_arguments "$@"
    validate_local_inputs

    if [[ "$PLAN_ONLY" == true ]]; then
        print_plan
        exit 0
    fi

    start_log
    trap on_exit EXIT

    log_info "Step 1/8: Verifying backup integrity and structure..."
    verify_backup

    log_info "Step 2/8: Checking the target cluster..."
    preflight_cluster

    local password
    log_info "Step 3/8: Reading target MongoDB credentials..."
    password="$(read_mongo_root_password)"

    log_info "Step 4/8: Discovering the target MongoDB primary..."
    REMOTE_POD="$(discover_primary "$password")"
    log_success "MongoDB primary: $REMOTE_POD"

    log_info "Step 5/8: Preparing a local TLS connection..."
    prepare_local_transport
    write_mongorestore_config "$password"

    log_info "Step 6/8: Validating the restore with mongorestore --dryRun..."
    run_mongorestore dry-run
    if [[ "$DRY_RUN" == true ]]; then
        unset password
        cleanup_local_transport
        trap - EXIT
        log_success "Restore dry run completed without changing target data."
        log_info "For a live restore, confirm target: RESTORE $TARGET_ID"
        exit 0
    fi

    log_info "Step 7/8: Confirming and replacing target databases..."
    confirm_exact_target
    ensure_primary_unchanged "$password"
    drop_target_databases "$password"
    run_mongorestore restore

    log_info "Step 8/8: Restoring requested secrets and validating databases..."
    apply_restore_secrets
    validate_restored_databases "$password"
    unset password

    RESTORE_SUCCEEDED=true
    cleanup_local_transport
    trap - EXIT
    log_success "Palette EC MongoDB restore completed successfully."
    log_warning "Keep Palette writers stopped until application-level validation is complete."
    log_info "Restore log: $LOG_FILE"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
