# spectro-tools

A consolidated collection of operational utilities for Spectro Cloud Palette
and Palette VerteX.

## Usage

Create the ignored shared configuration once, then enter the required tool
directory and follow its README:

```bash
cd spectro-tools
cp config/common-config.sh.tmpl config/common-config.sh

cd vertex-utilization
./vertex-utilization.sh --help
```

## Options

Each tool has its own interface and documents Usage and Options immediately
after its description. Use the tool's `--help` or `-h` option when available.

## Tools

| Directory | Purpose |
| --- | --- |
| [`ecr/`](ecr/README.md) | Download, push, and delete Palette air-gap content in Amazon ECR. |
| [`log_bundler/`](log_bundler/README.md) | Collect infrastructure diagnostics into a support bundle. |
| [`mongo-backup/`](mongo-backup/README.md) | Back up Palette MongoDB data and Kubernetes recovery Secrets. |
| [`mongo-restore/`](mongo-restore/README.md) | Restore a verified Palette MongoDB backup. |
| [`upgrade-check-v2/`](upgrade-check-v2/README.md) | Run pre-upgrade checks and collect recovery artifacts. |
| [`validate-iam/`](validate-iam/README.md) | Validate AWS IAM requirements for Palette deployment workflows. |
| [`vertex-utilization/`](vertex-utilization/README.md) | Report Palette VerteX core and KCH utilization. |
| `config/` | Shared configuration template and shell functions. |

## Requirements

Requirements vary by tool. Common dependencies include Bash, `kubectl`, AWS
CLI, `jq`, `curl`, Python 3, and MongoDB Database Tools. Install only the tools
listed in the selected project's README.

## Configuration

All shell utilities resolve and source `config/common-config.sh` and
`config/common-functions.sh` from their own locations. The tracked
`common-config.sh.tmpl` contains sections for ECR, `validate-iam`, and
`vertex-utilization`.

Values already present in the environment take precedence over shared
defaults. Some tools also support command-line options or explicitly selected
override files; their README defines the exact precedence.

The shared function library provides portable validation, command checks,
confirmation prompts, hashing, base64 decoding, Kubernetes helpers,
configuration loading, and ECR workflows. It is guarded against repeat
sourcing.

## Security and generated data

The local `config/common-config.sh` is ignored by Git. Keep credentials out of
the tracked template and prefer environment variables for passwords, API keys,
and tokens.

Root and tool-specific `.gitignore` files exclude local configurations,
kubeconfigs, private keys, support bundles, logs, backups, recovery artifacts,
downloads, and reports. Ignore rules do not protect files already tracked by
Git. Before committing, review `git diff --cached` and run an approved secret
scanner when available.

The original standalone project directories are not modified or removed by
this consolidation.
# spectro-tools
