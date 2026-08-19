# log_bundler

Collects Kubernetes resources, workload logs, and Palette infrastructure
diagnostics into a compressed support bundle. The archive can contain
sensitive cluster data and Kubernetes Secrets.

## Usage

```bash
cd spectro-tools/log_bundler
cp ../config/common-config.sh.tmpl ../config/common-config.sh  # first use only

export KUBECONFIG=/secure/path/management.kubeconfig
bash ./support-bundle-infra.sh [options]
```

## Options

| Option | Description |
| --- | --- |
| `-d DIR` | Create the temporary collection workspace beneath `DIR`. The final archive is written to the launch directory. |
| `-n NS1,NS2` | Add comma-separated namespaces to the collection. |
| `-r RESOURCE1,RESOURCE2` | Add comma-separated namespaced resource types. |
| `-R RESOURCE1,RESOURCE2` | Add comma-separated cluster-scoped resource types. |
| `-h` | Show built-in help. |

## Requirements

- Bash, `kubectl`, `tar`, and standard Unix text utilities.
- `KUBECONFIG` must be set to a readable management-cluster kubeconfig.
- Permission to list the targeted namespaces, pods, logs, Kubernetes
  resources, CRDs, and relevant cluster-scoped resources.
- Permission to execute in the Palette MongoDB pod for MongoDB diagnostics.

## Configuration

The script sources `../config/common-config.sh` and the shared functions. It
does not currently require tool-specific values from common-config; cluster
selection comes from `KUBECONFIG`.

The collector detects Enterprise and PCG management clusters and expands the
default namespace list accordingly. Use `-n`, `-r`, and `-R` only for
additional collection targets.

## Behavior

The collector validates namespace and RBAC coverage before creating a complete
bundle. It gathers:

- cluster-scoped and namespaced Kubernetes resources;
- current and previous pod logs;
- Helm release Secret manifests;
- cluster, storage, networking, and CRD state; and
- MongoDB status when the required pod access is available.

Collection stops instead of producing an incomplete archive when required
namespace or cluster-resource access is missing.

For MongoDB diagnostics, standard-cluster credentials are decoded locally and
sent to `kubectl exec -i` through standard input. TLS-enabled clusters use the
credential environment variables already present in the MongoDB container.
Passwords are passed to the Mongo shell as quoted arguments and are never
embedded in a generated shell command or printed by the collector.

## Output

The final file is named:

```text
<cluster-name>-YYYY-MM-DD_HH_MM_SS.tar.gz
```

The archive is written to the directory where the script was launched. The
temporary workspace is removed after archiving. Support archives and leftover
temporary directories are ignored by Git.

Archive creation is transactional: the script writes a temporary archive and
renames it only after `tar` succeeds. If archive creation or the final rename
fails, the script exits nonzero, removes an incomplete archive when applicable,
and preserves the collection workspace. The terminal output prints both the
workspace path and a `tar` command that can be used to retry archiving.

## Safety and troubleshooting

- Treat every support bundle as sensitive. Store and transfer it only through
  approved encrypted channels.
- Review RBAC errors in the console output and grant only the missing read or
  pod-log access before retrying.
- If `KUBECONFIG` is unset, export it explicitly; the script does not fall back
  to the default kubeconfig path.
- If MongoDB diagnostics fail, verify `exec` access to the running MongoDB pod
  in `hubble-system`.
