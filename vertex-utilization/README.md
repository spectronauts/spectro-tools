# vertex-utilization

Generates a CSV report of Alloy imported cores, Pure deployed cores,
Kubernetes core hours (KCH), and total CPU cores from Palette or Palette
VerteX.

## Usage

```bash
cd spectro-tools/vertex-utilization
cp ../config/common-config.sh.tmpl ../config/common-config.sh  # first use only

./vertex-utilization.sh

./vertex-utilization.sh \
  --project-uid PROJECT_UID \
  --output artifacts/project-utilization.csv
```

Values may also be supplied entirely on the command line:

```bash
./vertex-utilization.sh \
  --api-url https://vertex.example.com \
  --api-key API_KEY
```

## Options

| Option | Description |
| --- | --- |
| `--config FILE` | Load an optional allow-listed `KEY=VALUE` override file. |
| `--api-url URL` | Palette or VerteX API base URL. |
| `--api-key KEY` | Palette or VerteX API key. |
| `--project-uid UID` | Limit the report to one project. |
| `--output FILE` | CSV path; default `artifacts/utilization-report.csv`. |
| `--help` | Show built-in help. |

## Requirements

- Bash, `curl`, and `jq`.
- A Palette or Palette VerteX API key with access to dashboard projects.

On macOS, install `jq` with `brew install jq`.

## Configuration

Edit the `vertex-utilization` section of `../config/common-config.sh`:

```bash
: "${PALETTE_API_URL=https://vertex.example.com}"
: "${API_KEY=}"
: "${PROJECT_UID=}"
: "${OUTPUT_FILE=artifacts/utilization-report.csv}"
```

| Variable | Required | Purpose |
| --- | --- | --- |
| `PALETTE_API_URL` | Yes | API base URL; `https://` is added when no scheme is supplied. |
| `API_KEY` | Yes | API key sent to the dashboard projects endpoint. |
| `PROJECT_UID` | No | Limits the report to one project; empty reports every accessible project. |
| `OUTPUT_FILE` | No | CSV destination resolved from the launch directory. |
| `CONFIG_FILE` | No | Same as `--config`; not part of common-config. |

Keep `API_KEY` empty in the tracked template. Prefer exporting it for the
current shell even though the copied common-config is ignored:

```bash
export API_KEY='...'
```

Configuration precedence, highest first:

1. Command-line options.
2. An explicit `--config` file, or `CONFIG_FILE` when `--config` is absent.
3. Environment variables.
4. The ignored `../config/common-config.sh`.

An optional override file supports only the four report variables:

```bash
PALETTE_API_URL="https://vertex.example.com"
API_KEY="..."
PROJECT_UID=""
OUTPUT_FILE="artifacts/utilization-report.csv"
```

Only use override files you trust. `*.config` files are ignored by Git.

## Behavior

The script calls `/v1/dashboard/projects`, optionally selects one project UID,
and emits one row per cluster. It separates imported Alloy cores from Pure
deployed cores and calculates KCH as cores multiplied by 730 hours divided by
1,000.

## Output

When launched from this directory, the default file is:

```text
artifacts/utilization-report.csv
```

The parent directory is created automatically and ignored by Git. Each row
contains project name/tags, cluster name/UID, Alloy cores/KCH, Pure cores/KCH,
and total cores. A final `TOTAL` row sums all core and KCH columns.

The report contains organization and cluster metadata. Store and share it
according to your operational-data policy.
