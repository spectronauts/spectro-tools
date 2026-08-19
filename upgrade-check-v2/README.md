# upgrade-check-v2

Runs a read-mostly Palette VerteX pre-upgrade assessment, collects recovery
artifacts, and produces a post-upgrade checklist. A clean result is not an
upgrade authorization; review every warning and follow the approved upgrade
procedure.

## Usage

```bash
cd spectro-tools/upgrade-check-v2
cp ../config/common-config.sh.tmpl ../config/common-config.sh  # first use only

./upgrade-check.sh --target 4.9.38

./upgrade-check.sh \
  --context management-context \
  --target 4.9.38 \
  --confirm-path \
  --confirm-breaking-changes
```

For registry synchronization checks, provide a tenant credential through the
environment:

```bash
VERTEX_API_KEY='...' ./upgrade-check.sh \
  --target 4.9.38 \
  --api-url https://vertex.example.com
```

## Options

| Option | Description |
| --- | --- |
| `-t`, `--target VERSION` | Target VerteX version; prompted when omitted. |
| `-c`, `--context NAME` | kubectl context; default is the current context. |
| `-n`, `--namespace NAME` | Palette namespace; default `hubble-system`. |
| `--mongo-namespace NAME` | MongoDB namespace; default is the Palette namespace. |
| `--piraeus-namespace NAME` | Piraeus namespace; default `piraeus-system`. |
| `--api-url URL` | VerteX API base URL without `/system`. |
| `-k`, `--insecure` | Skip TLS verification for registry API checks. |
| `-o`, `--output PATH` | Artifact directory; default is a timestamped directory under `artifacts/`. |
| `--confirm-path` | Confirms the documented upgrade path was reviewed. |
| `--confirm-breaking-changes` | Confirms applicable breaking changes were addressed. |
| `--skip-etcd-snapshot` | Skip local etcd snapshot creation only. |
| `--no-color` | Disable colored output. |
| `--version` | Print the script version. |
| `-h`, `--help` | Show built-in help. |

Compatibility aliases remain available: `--target-version`, `--output-dir`,
`--upgrade-path-confirmed`, `--breaking-changes-confirmed`, and `--skip-backup`.

## Requirements

- Bash, `kubectl`, Helm, Python 3, `curl`, OpenSSL, and standard Unix tools.
- Optional `etcdutl` for local snapshot integrity validation.
- Read access to cluster health, Palette resources, storage resources, CRDs,
  ConfigMaps, and Secrets.
- Permission to execute in MongoDB and local etcd pods and to create/delete the
  temporary DNS test pod.
- For the etcd helper fallback, permission to create a hardened helper pod that
  mounts the exact snapshot hostPath read-only.

Full collection commonly requires cluster-admin-equivalent access. Air-gapped
clusters must be able to run the configured DNS and etcd helper images.

## Configuration

Command-line options override environment variables. The script sources
`../config/common-config.sh`, but its operational settings are supplied through
the options above or these advanced variables:

| Variable | Default | Purpose |
| --- | --- | --- |
| `MGMT_NAMESPACE` | `hubble-system` | Palette namespace. |
| `MONGO_NAMESPACE` | Palette namespace | MongoDB namespace. |
| `PIRAEUS_NAMESPACE` | `piraeus-system` | Piraeus/LINSTOR namespace. |
| `MONGO_SECRET`, `MONGO_POD` | `spectromongosecret`, `mongo-0` | MongoDB discovery and authentication. |
| `TARGET_VERSION`, `OUTPUT_DIR`, `KUBE_CONTEXT` | Unset | Option equivalents. |
| `VERTEX_API_URL` | Detected ingress | Registry API base URL. |
| `VERTEX_API_KEY` | Unset | Preferred tenant API credential. |
| `VERTEX_AUTH_TOKEN` | Unset | Alternative complete authorization-header value. |
| `INSECURE_TLS` | `false` | Disable registry API certificate validation. |
| `CONFIRM_PATH`, `CONFIRM_BREAKING` | `false` | Non-interactive review confirmations. |
| `SKIP_ETCD_SNAPSHOT`, `NO_COLOR` | `false` | Snapshot and display controls. |
| `ZOT_NODE_PORT` | `30003` | Expected Zot NodePort. |
| `REGISTRY_MAX_AGE_HOURS` | `48` | Maximum acceptable age of a successful sync. |
| `REGISTRY_RUNNING_WARN_HOURS` | `1` | Warn when syncing exceeds this duration. |
| `ETCD_HELPER_IMAGE`, `DNS_TEST_IMAGE` | `busybox:1.28` | Temporary helper images. |
| `UPGRADE_URL`, `BREAKING_URL` | Spectro documentation URLs | References displayed for operator review. |

Registry credentials are never written to the log or generated JSON.

## Behavior

The report contains seven sections:

1. Installation, context, current/target versions, upgrade path, and breaking
   changes.
2. Node, Palette pod, workload, and Helm health.
3. Authenticated MongoDB replica health, PVCs, DiskPressure, and
   Piraeus/LINSTOR.
4. cert-manager, TLS, Traefik, ingress, and endpoint certificate checks.
5. Zot, DNS, Palette API, and OCI/Helm/Pack registry synchronization.
6. Recovery readiness, local etcd health/snapshot, Secrets, storage
   passphrases, and version metadata.
7. A namespace-aware post-upgrade checklist.

Managed EKS, AKS, GKE, and OKE control planes are classified from cluster
metadata. Expected absence of control-plane nodes or local etcd is reported as
informational. Missing etcd on an unmanaged or unclassified cluster remains
`UNKNOWN`.

For visible local etcd, snapshot transfer tries an exec stream, `kubectl cp`,
then a hardened read-only helper pod. The helper's host snapshot may remain on
the control-plane node for the rollback window; its location is recorded in
the output values file.

This script validates MongoDB health but does not create a MongoDB backup.
Create and verify a separate approved MongoDB backup before upgrading.

## Output

The output directory is mode `700`; files are created under a restrictive
umask and ignored by Git. Important artifacts include:

| Artifact | Contents |
| --- | --- |
| `preupgrade-check.log` | Full report and diagnostics. |
| `pre-upgrade-values.env` | Detected context, versions, namespaces, ingress, and recovery values. |
| `registry-sync-status.json` | Sanitized registry synchronization details. |
| `etcd-snapshot-*.db` | Local etcd snapshot when applicable and enabled. |
| `secrets-*.yaml`, `tls-secrets-backup.yaml` | Sensitive Kubernetes recovery resources. |
| `linstor-passphrase-backup.yaml` | LINSTOR recovery passphrase when present. |
| `palette-version-*` | Palette version evidence. |
| `post-upgrade-checklist.md` | Rendered post-upgrade validation checklist. |

These files can contain credentials, private keys, and sensitive cluster
state. Move durable recovery artifacts to approved encrypted storage.

## Results and exit codes

| Code | Result |
| --- | --- |
| `0` | No blocking failures or unknown checks; review warnings. |
| `1` | One or more failures; do not begin the upgrade. |
| `2` | Invalid invocation, missing prerequisite, or inconclusive `UNKNOWN` checks. |
