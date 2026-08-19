# mongo-backup

Creates a logical backup of Palette MongoDB databases and the Kubernetes
Secrets required for recovery. Backups contain production data and must be
stored as sensitive recovery artifacts.

## Usage

```bash
cd spectro-tools/mongo-backup
cp ../config/common-config.sh.tmpl ../config/common-config.sh  # first use only

# Verify local prerequisites.
./palette-ec-backup.sh --check-prerequisites

# Preview the backup plan without creating a backup.
./palette-ec-backup.sh \
  --kubeconfig ./source.kubeconfig \
  --agent-upgrade-paused \
  --dry-run

# Create the backup.
./palette-ec-backup.sh \
  --kubeconfig ./source.kubeconfig \
  --agent-upgrade-paused
```

## Options

| Option | Description |
| --- | --- |
| `-k`, `--kubeconfig FILE` | Source-cluster kubeconfig; required for backup and dry run. |
| `--agent-upgrade-paused` | Confirms **Pause Agent Upgrade** is enabled; required for backup. |
| `-n`, `--namespace NAME` | Palette namespace; default `hubble-system`. |
| `-a`, `--artifacts-dir DIR` | Output root; default `artifacts/` beside the script. |
| `--mongo-pod NAME` | Pod used for replica-set discovery; default `mongo-0`. |
| `--local-port PORT` | Fixed loopback port; default is an automatically selected free port. |
| `--check-prerequisites` | Verify local tools and bundled packages, then exit. |
| `--dry-run` | Validate prerequisites and display the plan without creating a backup. |
| `--version` | Print the script version. |
| `-h`, `--help` | Show built-in help. |

The package helper supports:

```bash
sudo ./install-prerequisites.sh
./install-prerequisites.sh --verify-only
```

## Requirements

- Bash, Python 3, `kubectl`, and standard Unix utilities.
- MongoDB Database Tools with a compatible `mongodump` on `PATH`.
- Permission to read the Palette namespace and Secrets, execute in MongoDB
  pods, and port-forward a MongoDB pod.
- MongoDB Server 6, 7, or 8.

Bundled Database Tools `100.17.0` packages are provided for Ubuntu 24.04 x86-64
and Rocky Linux 9 x86-64. Other platforms must install compatible tools
separately. Package checksums and details are in
[`artifacts/packages/README.md`](artifacts/packages/README.md).

## Configuration

The script sources `../config/common-config.sh`. Backup-specific settings use
command-line options or these advanced environment variables:

| Variable | Default | Purpose |
| --- | --- | --- |
| `MONGO_PORT` | `27017` | MongoDB service port. |
| `MONGO_USER` | `root` | MongoDB user. |
| `AUTH_DB` | `admin` | Authentication database. |
| `MONGO_SECRET` | `spectromongosecret` | Secret containing the root password. |

Command-line options take precedence for namespace, artifact directory,
query pod, and local port.

## Behavior

The backup workflow:

1. Validates local tools, cluster access, MongoDB pods, and required Secrets.
2. Detects the MongoDB version and healthy replica-set primary.
3. Exports sanitized `configserversecret` and `msgbroker-secret` resources.
4. Copies client TLS material to a restricted temporary directory and opens a
   loopback-only port-forward.
5. Runs compressed dumps for required `hubbledb` and
   `hubble_timeseriesdb`, plus optional `hubble_archivedb` when available.
6. Verifies outputs and writes a summary, completion marker, and checksums.
7. Removes temporary credentials, TLS files, and the port-forward.

The MongoDB password is passed through a mode-`600` temporary configuration
file and is not printed in the command line or logs.

## Output

```text
artifacts/
├── palette-mongo-backup-YYYYmmdd-HHMMSS.log
└── palette-mongo-backup-YYYYmmdd-HHMMSS/
    ├── COMPLETED
    ├── SHA256SUMS
    ├── backup-summary.txt
    ├── databases/
    │   ├── hubbledb/
    │   ├── hubble_timeseriesdb/
    │   └── hubble_archivedb/       # optional
    └── secrets/
        ├── configserversecret.json
        └── msgbroker-secret.json
```

A failed run retains `INCOMPLETE` after backup creation begins. Verify a
completed backup before transfer:

```bash
cd artifacts/palette-mongo-backup-YYYYmmdd-HHMMSS
sha256sum --check SHA256SUMS       # Linux
shasum -a 256 --check SHA256SUMS  # macOS
```

Use `--artifacts-dir /secure/path` to write directly to encrypted or separately
mounted storage.

## Safety and exit codes

- Enable **Tenant Settings → Platform Settings → Pause Agent Upgrade** before
  backup and keep it enabled until the run finishes.
- Move completed backups to approved encrypted storage and restrict access.
- A backup is not validated recovery until it has passed an approved restore
  test with compatible MongoDB Database Tools.

| Code | Meaning |
| --- | --- |
| `0` | Success. |
| `1` | Prerequisite, cluster, or backup failure. |
| `2` | Invalid command-line usage. |
