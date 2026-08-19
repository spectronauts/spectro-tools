#!/bin/bash
set -eu

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
COMMON_CONFIG="${SCRIPT_DIR}/../config/common-config.sh"
COMMON_FUNCTIONS="${SCRIPT_DIR}/../config/common-functions.sh"
# shellcheck source=../config/common-config.sh
source "${COMMON_CONFIG}"
# shellcheck source=../config/common-functions.sh
source "${COMMON_FUNCTIONS}"

function usage() {
  cat <<EOF
Usage: $0 [--config <file>] --api-url <url> --api-key <key> [options]

Options:
  --config <file>     Load an optional override file (KEY=VALUE format)
  --api-url <url>     Palette / VerteX API base URL (e.g. https://vertex.example.com)
  --api-key <key>     Palette / VerteX API key
  --project-uid <uid> Optional project UID to scope the query
  --output <file>     CSV output file (default: artifacts/utilization-report.csv)
  --help              Show this help message

Environment variables can be used instead of command-line options:
  PALETTE_API_URL     Same as --api-url
  API_KEY             Same as --api-key
  PROJECT_UID         Same as --project-uid
  OUTPUT_FILE         Same as --output
  CONFIG_FILE         Same as --config

Config file format: KEY=VALUE
Supported config keys: PALETTE_API_URL API_KEY PROJECT_UID OUTPUT_FILE

Defaults are loaded from ../config/common-config.sh.

Example:
  $0 --output artifacts/cores.csv
  $0 --config /secure/path/vertex.config
EOF
  exit 0
}

function parse_args() {
  local config_file="${CONFIG_FILE:-}"
  local args=("$@")
  local i=0
  while [[ $i -lt $# ]]; do
    case "${args[$i]}" in
      --config)
        ((i++))
        [[ $i -lt $# ]] || { echo "Error: --config requires a file path" >&2; exit 1; }
        config_file="${args[$i]}"
        ;;
    esac
    ((i++))
  done

  [[ -n "$config_file" ]] && load_config_values --overwrite "$config_file" \
    PALETTE_API_URL API_KEY PROJECT_UID OUTPUT_FILE

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --config)      shift 2 ;;
      --api-url)     PALETTE_API_URL="$2"; shift 2 ;;
      --api-key)     API_KEY="$2";         shift 2 ;;
      --project-uid) PROJECT_UID="$2";     shift 2 ;;
      --output)      OUTPUT_FILE="$2";     shift 2 ;;
      --help)        usage ;;
      *)
        echo "Error: unknown option: $1" >&2
        echo "Use --help for usage information" >&2
        exit 1
        ;;
    esac
  done
}

PALETTE_API_URL="${PALETTE_API_URL:-${PALETTE_API_URL_ENV:-}}"
API_KEY="${API_KEY:-${API_KEY_ENV:-}}"
PROJECT_UID="${PROJECT_UID:-${PROJECT_UID_ENV:-}}"

parse_args "$@"

OUTPUT_FILE="${OUTPUT_FILE:-artifacts/utilization-report.csv}"

if [[ -z "${PALETTE_API_URL}" || -z "${API_KEY}" ]]; then
  echo "Error: PALETTE_API_URL and API_KEY must both be set (via command-line or environment)" >&2
  echo "Set them in ../config/common-config.sh or use an optional --config override file." >&2
  echo "Use --help for usage information" >&2
  exit 1
fi

# Ensure PALETTE_API_URL has a scheme (config files often omit https://).
PALETTE_API_URL="${PALETTE_API_URL%/}"
if [[ "$PALETTE_API_URL" != http://* && "$PALETTE_API_URL" != https://* ]]; then
  PALETTE_API_URL="https://${PALETTE_API_URL}"
fi

echo "Fetching cores under management from Palette VerteX..."
echo "Output file: $OUTPUT_FILE"
mkdir -p "$(dirname -- "$OUTPUT_FILE")"

function get_project_cores() {
  local project_uid=$1
  local response

  # The dashboard endpoint populates status.usage.clusters; the single-project
  # GET /v1/projects/{uid} endpoint does not.
  response=$(curl -s -L "${PALETTE_API_URL}/v1/dashboard/projects" \
    -X POST \
    -H "ApiKey: ${API_KEY}" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json" \
    -d '{}')

  if [ -n "$project_uid" ]; then
    response=$(echo "$response" | jq --arg uid "$project_uid" '
      { items: [(.items // [])[] | select(.metadata.uid == $uid)] }
    ')
    if [ "$(echo "$response" | jq '.items | length')" -eq 0 ]; then
      echo "Error: no project found with UID: $project_uid" >&2
      exit 1
    fi
  fi

  echo "$response"
}

function calculate_cores() {
  local json_data=$1
  local output_file=$2

  if ! command -v jq &> /dev/null; then
    echo "Error: jq is required but not installed."
    echo "Install it with: brew install jq"
    exit 1
  fi

  # CSV header — one row per cluster
  echo "Palette Instance:,$PALETTE_API_URL" > "$output_file"
  echo "ProjectName,ProjectTags,ClusterName,ClusterUID,AlloyImportedCPUCores,AlloyKCH,PureDeployedCPUCores,PureKCH,TotalCores" >> "$output_file"

  # Emit one row per cluster within each project.
  # isAlloy=true  → Alloy (imported) cores
  # isAlloy=false → Pure (deployed) cores
  # KCH = cores * 730 / 1000
  echo "$json_data" | jq -r '
    # Normalise: wrap a single-project response in an items array
    (if .items then .items else [.] end) |
    .[] |
    . as $proj |
    ($proj.metadata.name // "Unknown") as $pname |
    (($proj.metadata.labels // {}) | to_entries | map("\(.key):\(.value)") | join(";")) as $tags |
    ($proj.status.usage.clusters // []) |
    if length == 0 then
      # Project has no clusters — emit a zero row so it still appears
      "\($pname),\($tags),(no clusters),,0,0,0,0,0"
    else
      .[] |
      ($proj.metadata.name // "Unknown") as $pname2 |
      (($proj.metadata.labels // {}) | to_entries | map("\(.key):\(.value)") | join(";")) as $tags2 |
      (.cpuCores / 1000) as $cores |
      (if .isAlloy then $cores else 0 end) as $alloy |
      (if .isAlloy then 0 else $cores end) as $pure |
      "\($pname2),\($tags2),\(.name // "Unknown"),\(.uid // ""),\($alloy),\($alloy * 730 / 1000),\($pure),\($pure * 730 / 1000),\($cores)"
    end
  ' >> "$output_file"

  # Grand-total row
  # FIX: parenthesise `// []` so the `|` that follows iterates into the
  # clusters array rather than being absorbed into the alternative operator.
  # Before: `.[].status.usage.clusters // [] | .[]`  ← // has lower
  #         precedence than |, so jq parsed this as:
  #         `.[].status.usage.clusters // ([] | .[])` — the array was
  #         never iterated and .isAlloy/.cpuCores were called on the array.
  # After:  `.[] | (.status.usage.clusters // [])[]`  ← explicit grouping.
  local alloy_total pure_total total alloy_kch_total pure_kch_total
  alloy_total=$(echo "$json_data" | jq '
    (if .items then .items else [.] end) |
    [.[] | (.status.usage.clusters // [])[] | select(.isAlloy) | .cpuCores / 1000] | add // 0
  ')
  pure_total=$(echo "$json_data" | jq '
    (if .items then .items else [.] end) |
    [.[] | (.status.usage.clusters // [])[] | select(.isAlloy | not) | .cpuCores / 1000] | add // 0
  ')
  total=$(echo "$json_data" | jq '
    (if .items then .items else [.] end) |
    [.[] | (.status.usage.clusters // [])[] | .cpuCores / 1000] | add // 0
  ')
  alloy_kch_total=$(echo "$alloy_total" | jq '. * 730 / 1000')
  pure_kch_total=$(echo "$pure_total" | jq '. * 730 / 1000')

  echo "TOTAL,,,,${alloy_total},${alloy_kch_total},${pure_total},${pure_kch_total},${total}" >> "$output_file"

  echo ""
  echo "✓ Data written to: $output_file"
  echo "***********************"
  echo "Total CPU Cores: $total"
  echo "***********************"
}

# Main
response=$(get_project_cores "$PROJECT_UID")

if [ $? -eq 0 ] && [ -n "$response" ]; then
  calculate_cores "$response" "$OUTPUT_FILE"
else
  echo "Error: Failed to fetch data from Palette API"
  echo "Response: $response"
  exit 1
fi
