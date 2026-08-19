# MongoDB Database Tools packages

Bundled MongoDB Database Tools `100.17.0` packages used by the `mongo-backup`
prerequisite installer.

## Usage

Run from the `mongo-backup` directory:

```bash
# Verify both bundled package checksums without changing the host.
./install-prerequisites.sh --verify-only

# Install the package matching a supported host.
sudo ./install-prerequisites.sh
```

## Options

| Option | Description |
| --- | --- |
| `--verify-only` | Verify the bundled DEB and RPM checksums, then exit. |
| `-h`, `--help` | Show installer help. |

## Requirements

| Operating system | CPU | Bundled package |
| --- | --- | --- |
| Ubuntu 24.04 | x86-64 | `mongodb-database-tools-ubuntu2404-x86_64-100.17.0.deb` |
| Rocky Linux 9 | x86-64 | `mongodb-database-tools-rhel93-x86_64-100.17.0.rpm` |

The installer adds required standard OS packages but does not install
`kubectl` or upgrade the operating system.

## Other platforms

macOS, Windows, ARM64, other Linux distributions, and unlisted releases must
install compatible MongoDB Database Tools separately. After installation:

```bash
mongodump --version
./palette-ec-backup.sh --check-prerequisites
```

The backup records the installed version but does not require exactly
`100.17.0`.

## Package integrity

`SHA256SUMS` contains the recorded package hashes. Both the backup script and
prerequisite installer verify the files before use.

Upstream packages:

- `https://fastdl.mongodb.org/tools/db/mongodb-database-tools-ubuntu2404-x86_64-100.17.0.deb`
- `https://fastdl.mongodb.org/tools/db/mongodb-database-tools-rhel93-x86_64-100.17.0.rpm`

For compatibility guidance, see the
[MongoDB Database Tools documentation](https://www.mongodb.com/docs/database-tools/mongodump/mongodump-compatibility-and-installation/).
