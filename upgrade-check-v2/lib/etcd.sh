#!/usr/bin/env bash

ETCD_LIB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../config/common-config.sh
source "${ETCD_LIB_DIR}/../../config/common-config.sh"
# shellcheck source=../../config/common-functions.sh
source "${ETCD_LIB_DIR}/../../config/common-functions.sh"

ETCD_CA=/etc/kubernetes/pki/etcd/ca.crt
ETCD_CERT=/etc/kubernetes/pki/etcd/server.crt
ETCD_KEY=/etc/kubernetes/pki/etcd/server.key

etcd_exec() {
  local pod="$1"
  shift
  kube exec -n kube-system "$pod" -- "$@"
}

etcd_hostpath_transfer() {
  local pod="$1"
  local destination="$2"
  local pod_json mapping node container mount_path host_path
  local filename remote_file host_file helper overrides

  pod_json=$(kube get pod -n kube-system "$pod" -o json 2>>"$LOG") || return 1
  mapping=$(printf '%s' "$pod_json" | python3 -c '
import json, os, sys
spec = json.load(sys.stdin).get("spec", {})
host_paths = {
    volume.get("name"): (volume.get("hostPath") or {}).get("path", "")
    for volume in spec.get("volumes", [])
}
for container in spec.get("containers", []):
    command = (container.get("command") or []) + (container.get("args") or [])
    if container.get("name") != "etcd" and "etcd" not in " ".join(command):
        continue
    data_dir = "/var/lib/etcd"
    for index, argument in enumerate(command):
        if argument.startswith("--data-dir="):
            data_dir = argument.split("=", 1)[1]
        elif argument == "--data-dir" and index + 1 < len(command):
            data_dir = command[index + 1]
    choices = []
    for volume_mount in container.get("volumeMounts", []):
        mount = (volume_mount.get("mountPath") or "").rstrip("/") or "/"
        host = host_paths.get(volume_mount.get("name"), "")
        if not host or volume_mount.get("readOnly") or volume_mount.get("subPathExpr"):
            continue
        if data_dir == mount or data_dir.startswith(mount.rstrip("/") + "/"):
            sub_path = volume_mount.get("subPath", "")
            choices.append((len(mount), mount, os.path.join(host, sub_path) if sub_path else host))
    if choices and spec.get("nodeName"):
        _, mount, host = max(choices)
        values = (spec["nodeName"], container.get("name", "etcd"), mount, host)
        if all(values) and not any("\t" in value or "\n" in value for value in values):
            print("\t".join(values))
            sys.exit(0)
sys.exit(1)
' 2>>"$LOG") || return 1

  IFS=$'\t' read -r node container mount_path host_path <<< "$mapping"
  filename="palette-preupgrade-${RUN_ID}-$$.db"
  remote_file="${mount_path%/}/$filename"
  host_file="${host_path%/}/$filename"
  helper="etcd-snapshot-reader-$$"

  info "Direct transfer tools unavailable; preparing a read-only helper on $node"
  kube exec -n kube-system "$pod" -c "$container" -- \
    etcdctl snapshot save "$remote_file" \
    --cacert="$ETCD_CA" --cert="$ETCD_CERT" --key="$ETCD_KEY" \
    >>"$LOG" 2>&1 || return 1

  overrides=$(python3 -c 'import json, sys
name, image, node, host_file = sys.argv[1:]
print(json.dumps({"spec": {
    "nodeName": node,
    "automountServiceAccountToken": False,
    "restartPolicy": "Never",
    "tolerations": [{"operator": "Exists"}],
    "containers": [{
        "name": name,
        "image": image,
        "imagePullPolicy": "IfNotPresent",
        "command": ["sleep", "300"],
        "securityContext": {
            "allowPrivilegeEscalation": False,
            "readOnlyRootFilesystem": True,
            "runAsUser": 0,
            "capabilities": {"drop": ["ALL"]}
        },
        "volumeMounts": [{
            "name": "snapshot",
            "mountPath": "/snapshot/etcd.db",
            "readOnly": True
        }]
    }],
    "volumes": [{
        "name": "snapshot",
        "hostPath": {"path": host_file, "type": "File"}
    }]
}}))' "$helper" "$ETCD_HELPER_IMAGE" "$node" "$host_file")

  kube run "$helper" -n kube-system --image="$ETCD_HELPER_IMAGE" \
    --restart=Never --overrides="$overrides" --command -- sleep 300 \
    >>"$LOG" 2>&1 || return 1
  register_temp_pod kube-system "$helper"

  if ! kube wait -n kube-system --for=condition=Ready "pod/$helper" \
    --timeout=60s >>"$LOG" 2>&1; then
    delete_temp_pod kube-system "$helper"
    return 1
  fi
  if ! kube exec -n kube-system "$helper" -- cat /snapshot/etcd.db \
    > "$destination" 2>>"$LOG"; then
    delete_temp_pod kube-system "$helper"
    return 1
  fi
  delete_temp_pod kube-system "$helper"

  ETCD_TRANSFER_METHOD="read-only hostPath helper"
  ETCD_HOST_SNAPSHOT_NODE="$node"
  ETCD_HOST_SNAPSHOT_PATH="$host_file"
}

etcd_create_snapshot() {
  local pod="$1"
  local final="$OUTPUT_DIR/etcd-snapshot-${RUN_ID}.db"
  local partial="${final}.partial"
  local remote="/tmp/palette-preupgrade-${RUN_ID}-$$.db"

  info "Creating an etcd snapshot"
  if ! etcd_exec "$pod" etcdctl snapshot save "$remote" \
    --cacert="$ETCD_CA" --cert="$ETCD_CERT" --key="$ETCD_KEY" \
    >>"$LOG" 2>&1; then
    fail "etcd snapshot creation failed"
    return
  fi

  ETCD_TRANSFER_METHOD=""
  ETCD_HOST_SNAPSHOT_NODE=""
  ETCD_HOST_SNAPSHOT_PATH=""
  if etcd_exec "$pod" cat "$remote" > "$partial" 2>>"$LOG"; then
    ETCD_TRANSFER_METHOD="kubectl exec stream"
  elif kube cp "kube-system/$pod:$remote" "$partial" 2>>"$LOG"; then
    ETCD_TRANSFER_METHOD="kubectl cp"
  elif etcd_hostpath_transfer "$pod" "$partial"; then
    :
  fi

  if [[ -z "$ETCD_TRANSFER_METHOD" ]]; then
    fail "etcd snapshot exists in $pod but could not be transferred locally"
    detail "Direct, kubectl cp, and hostPath helper transfers all failed; review $LOG"
    return
  fi
  if [[ ! -s "$partial" ]]; then
    fail "etcd snapshot transfer produced an empty file: $partial"
    return
  fi
  if command -v etcdutl >/dev/null 2>&1 \
    && ! etcdutl snapshot status "$partial" >>"$LOG" 2>&1; then
    fail "etcd snapshot integrity validation failed: $partial"
    return
  fi

  mv "$partial" "$final"
  pass "etcd snapshot saved: $final ($(wc -c < "$final" | tr -d ' ') bytes via $ETCD_TRANSFER_METHOD)"
  if [[ -n "$ETCD_HOST_SNAPSHOT_PATH" ]]; then
    warn "An additional etcd snapshot remains on node $ETCD_HOST_SNAPSHOT_NODE"
    detail "Host path: $ETCD_HOST_SNAPSHOT_PATH"
    detail "Retain it for the rollback window, then remove it through approved node access"
    record_value ETCD_HOST_SNAPSHOT_NODE "$ETCD_HOST_SNAPSHOT_NODE"
    record_value ETCD_HOST_SNAPSHOT_PATH "$ETCD_HOST_SNAPSHOT_PATH"
  fi
}

check_etcd() {
  local data unhealthy
  info "Checking etcd health"
  if ! data=$(kube get pods -n kube-system --no-headers 2>>"$LOG"); then
    unknown "Could not query etcd pods"
    return
  fi

  ETCD_POD=$(printf '%s\n' "$data" | awk '$1 ~ /^etcd-/ {print $1; exit}')
  if [[ -z "$ETCD_POD" ]]; then
    if [[ "${CONTROL_PLANE_MODE:-unknown}" == "managed" ]]; then
      info "etcd is managed by ${CLUSTER_PLATFORM:-the Kubernetes provider} and is not exposed as a cluster pod"
      detail "Local etcd health and snapshot checks are not applicable; use the provider-supported backup and recovery controls."
    else
      unknown "No local etcd pod found; verify the control-plane topology and backup process"
    fi
    return
  fi

  unhealthy=$(printf '%s\n' "$data" | awk '$1 ~ /^etcd-/ && $3 != "Running" {print $1, $3}')
  if [[ -n "$unhealthy" ]]; then
    fail "One or more etcd pods are unhealthy"
    detail "$unhealthy"
  else
    pass "Local etcd pods are Running"
  fi

  if ETCD_HEALTH=$(etcd_exec "$ETCD_POD" etcdctl endpoint health \
    --cacert="$ETCD_CA" --cert="$ETCD_CERT" --key="$ETCD_KEY" 2>>"$LOG") \
    && [[ "$ETCD_HEALTH" == *"is healthy"* ]]; then
    pass "etcd endpoint is healthy"
    detail "$ETCD_HEALTH"
  else
    fail "etcd endpoint health check failed"
    detail "${ETCD_HEALTH:-No health response}"
  fi

  if [[ "$SKIP_ETCD_SNAPSHOT" == "true" ]]; then
    warn "etcd snapshot skipped by operator request"
  else
    etcd_create_snapshot "$ETCD_POD"
  fi
}
