# ecr

Utilities for downloading, extracting, pushing, and deleting Palette VerteX
air-gap content in Amazon ECR. Run the scripts from this directory after
creating the shared configuration.

## Usage

```bash
cd spectro-tools/ecr
cp ../config/common-config.sh.tmpl ../config/common-config.sh  # first use only

# Push a complete air-gap installer.
./push_bin_to_ecr.sh [version] [--skip-extraction]

# Push local bundle files.
./push_zst_to_ecr.sh BUNDLE_DIR

# Download, verify, and push bundles listed in a file.
./push_from_url.sh URL_FILE

# Permanently delete the configured ECR repository tree.
./delete_ecr_images.sh
```

## Options and arguments

| Script | Option or argument | Description |
| --- | --- | --- |
| `push_bin_to_ecr.sh` | `version` | Optional VerteX version; overrides `VERTEX_VERSION`. |
| `push_bin_to_ecr.sh` | `-s`, `--skip-extraction` | Reuse `AIRGAP_DIR` instead of extracting the installer. |
| `push_zst_to_ecr.sh` | `BUNDLE_DIR` | Directory containing one or more `.zst` bundles. |
| `push_from_url.sh` | `URL_FILE` | Text file containing one bundle URL per line; blank lines and comments are ignored. |
| `delete_ecr_images.sh` | none | Requires an interactive exact-path confirmation. |

Run `./push_bin_to_ecr.sh --help` for its built-in help.

## Requirements

- AWS CLI credentials with access to the configured ECR registry.
- `push_bin_to_ecr.sh`: Docker with a running daemon, ORAS, `jq`, `zip`, and
  `unzip`; `curl` is also needed when the installer must be downloaded.
- Bundle push scripts: Linux, the Palette CLI, and the AWS CLI. These scripts
  reject macOS because a compatible Palette CLI is unavailable there.
- `push_from_url.sh`: `curl`, OpenSSL, download credentials, and
  `downloads/spectro_public_key.pem`.
- Deletion: `ecr:DescribeRepositories` and `ecr:DeleteRepository` permission.

## Configuration

Edit the ECR section of `../config/common-config.sh`. Environment variables
set before launch take precedence over its defaults.

| Variable | Purpose |
| --- | --- |
| `VERTEX_VERSION` | Air-gap release used to derive installer and extraction paths. |
| `AWS_ACCOUNT`, `AWS_REGION` | ECR owner account and region. |
| `ECR_REGISTRY` | Registry hostname, normally derived from account and region. |
| `ECR_BASE_CONTENT_PATH` | Root repository namespace. |
| `ECR_IMAGE_BASE`, `ECR_PACK_BASE` | Image and optional pack path components. |
| `ECR_IMAGE_REGISTRY_TYPE`, `ECR_PACK_REGISTRY_TYPE` | Registry types passed to extracted push tooling. |
| `DOWNLOAD_USER`, `DOWNLOAD_PASS` | Credentials used only for protected downloads. Prefer exporting the password. |
| `BINARY`, `AIRGAP_DIR` | Installer and extraction paths. |
| `SKIP_EXTRACTION` | Reuse existing extracted content when `true`. |
| `ECR_DELETE_PATH` | Repository prefix eligible for permanent deletion. |

The normal destinations are:

```text
Images: <registry>/<base-content-path>/spectro-images/...
Packs:  <registry>/<base-content-path>/spectro-packs/...
```

The Palette CLI and air-gap tooling add `spectro-packs` automatically. A
trailing `spectro-packs` in either configured pack path is normalized away so
the destination never contains `spectro-packs/spectro-packs`.

## Behavior

- `push_bin_to_ecr.sh` verifies prerequisites, downloads the installer when
  absent, extracts it unless skipped, authenticates Docker and ORAS, creates
  missing repositories, and runs the extracted image and pack push workflows.
- `push_zst_to_ecr.sh` authenticates the Palette CLI and pushes every `.zst`
  file in the supplied directory. It continues after individual failures and
  exits nonzero when any bundle fails.
- `push_from_url.sh` downloads bundles with basic authentication, verifies
  their signatures using the tracked Spectro public key, and pushes only
  verified bundles.
- `delete_ecr_images.sh` selects only the exact `ECR_DELETE_PATH` repository
  and descendants, displays them, and requires the full registry path to be
  typed before deletion.

## Output

Downloaded installers and bundles are stored under `downloads/`. Extracted
content is stored beneath `AIRGAP_DIR`, and push logs are written under
`logs/`. These generated files are ignored by Git; the public verification key
remains tracked.

## Safety and troubleshooting

- ECR repository deletion uses `aws ecr delete-repository --force` and cannot
  be undone. Confirm the account, region, and complete path before proceeding.
- `push_zst_to_ecr.sh` and `push_from_url.sh` use the Palette CLI's
  `--insecure` push option. Confirm that is acceptable for the target registry.
- If extraction already exists, use `--skip-extraction` only after verifying
  that `AIRGAP_DIR` matches the intended version.
- Authentication failures usually indicate expired AWS credentials, an
  incorrect region/account, a stopped Docker daemon, or missing ECR access.
- Existing tags are inspected before pushes; review warnings before replacing
  content.
