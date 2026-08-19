# mongo-restore

Destructive restore companion for `mongo-backup`. It restores the required
`hubbledb` and `hubble_timeseriesdb` databases, includes `hubble_archivedb` when
that optional database is present in the backup, and can optionally apply saved
application Secrets. It does not stop or restart Palette workloads.

## Usage

```bash
cd spectro-tools/mongo-restore
cp ../config/common-config.sh.tmpl ../config/common-config.sh  # first use only

# Inspect arguments without connecting to the target.
./palette-ec-restore.sh \
  --kubeconfig ./target.kubeconfig \
  --backup-dir /secure/path/palette-mongo-backup-TIMESTAMP \
  --plan

# Verify the backup and run mongorestore --dryRun against the target.
./palette-ec-restore.sh \
  --kubeconfig ./target.kubeconfig \
  --backup-dir /secure/path/palette-mongo-backup-TIMESTAMP \
  --dry-run
```

Run a live restore only after the dry run prints the exact target identity:

```bash
./palette-ec-restore.sh \
  --kubeconfig ./target.kubeconfig \
  --backup-dir /secure/path/palette-mongo-backup-TIMESTAMP \
  --agent-upgrade-paused \
  --application-writers-stopped \
  --target-backup-confirmed
```

## Options

| Option | Description |
| --- | --- |
| `--kubeconfig FILE` | Target-cluster kubeconfig; required. |
| `--backup-dir DIR` | Completed `mongo-backup` directory; required. |
| `--plan` | Validate local arguments and print the workflow without connecting. |
| `--dry-run` | Verify checksums, connect to the target, and run `mongorestore --dryRun`. |
| `--agent-upgrade-paused` | Confirms **Pause Agent Upgrade** is enabled; required live. |
| `--application-writers-stopped` | Confirms Palette database writers are stopped; required live. |
| `--target-backup-confirmed` | Confirms a target rollback backup or snapshot exists; required live. |
| `--restore-secrets` | Apply saved application Secrets after database restore succeeds. |
| `--confirm-target VALUE` | Non-interactive confirmation; must equal `RESTORE <context>/<namespace>`. |
| `--namespace NAME` | Palette namespace; default `hubble-system`. |
| `--log-dir DIR` | Restore log directory; default `logs/` beside the script. |
| `-h`, `--help` | Show built-in help. |

`--plan` and `--dry-run` are mutually exclusive. There is no general `--yes`
bypass.

## Requirements

- Bash 3.2 or newer, Python 3, `kubectl`, and standard Unix utilities.
- MongoDB Database Tools with a compatible `mongorestore`.
- `sha256sum` on Linux or `shasum` on macOS.
- Permission to read `spectromongosecret`, list and execute in MongoDB pods,
  and port-forward a pod.
- Permission to server-validate and apply Secrets when using
  `--restore-secrets`.
- A target MongoDB deployment compatible with the source dump's major version
  and feature compatibility version.

## Configuration

The script sources `../config/common-config.sh`. Restore-specific options use
the command line or these environment variables:

| Variable | Default | Purpose |
| --- | --- | --- |
| `LOG_DIR` | `logs/` beside the script | Restore logs. |
| `NAMESPACE` | `hubble-system` | Target Palette namespace. |
| `MONGO_PORT` | `27017` | MongoDB service port. |
| `MONGO_USER` | `root` | MongoDB user. |
| `AUTH_DB` | `admin` | Authentication database. |
| `MONGO_SECRET` | `spectromongosecret` | Target password Secret. |
| `MONGO_QUERY_POD` | `mongo-0` | Initial pod for primary discovery. |
| `MONGO_LOCAL_PORT` | Automatically selected | Optional fixed loopback port. |

Command-line namespace and log-directory options override environment values.

## Behavior

A dry run verifies the `COMPLETED` marker, rejects `INCOMPLETE`, validates every
checksum, requires `databases/hubbledb` and `databases/hubble_timeseriesdb`, and
includes `databases/hubble_archivedb` only when it is present and valid. It then
discovers the target primary, copies TLS material to a restricted temporary
directory, opens a loopback port-forward, and runs `mongorestore --dryRun`. It
does not change target databases or Secrets.

A live restore repeats those checks, verifies that the primary has not changed,
drops only the databases selected from the backup, restores with
`--stopOnError`, and confirms that each restored database contains collections.
If `hubble_archivedb` is absent from the backup, the target archive database is
left untouched. Saved application Secrets from `secrets/*.json` are
server-validated before database deletion and applied only after a successful
database restore.

The target `spectromongosecret` is always retained; the source MongoDB root
password is not stored in the backup.

## Output

Logs are written beneath `LOG_DIR` with mode `0600` and are ignored by Git.
Temporary MongoDB credentials, TLS files, and the loopback port-forward are
removed on exit.

The dry run prints the confirmation required for live execution:

```text
RESTORE target-context/hubble-system
```

For approved automation, pass that exact value with `--confirm-target`.

## Safety and recovery

Before a live restore:

1. Verify source and target MongoDB compatibility.
2. Enable **Pause Agent Upgrade**.
3. Block user and API activity.
4. Stop Palette database writers using the approved shutdown order while
   keeping MongoDB running.
5. Create and verify a target rollback backup or volume snapshot.

Use `--restore-secrets` only when the application Secrets must also be
recovered; applying older Secrets unnecessarily can break integrations.

If a live restore fails, keep writers stopped. Recover from the verified
rollback point or clear the partially restored databases before retrying. After
success, restart Palette in the approved order, verify pods, logs, login,
projects, clusters, agents, and replica health, then take a new backup before
reopening access.
