#!/bin/bash
set -eo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHART_DIR="$TEST_DIR/.."

if [ -z "$1" ]; then
  echo "Usage: $0 <values-file> [output-file]"
  echo "Example: $0 values-full.yaml control.toml"
  exit 1
fi

VALUES_FILE="$1"

rendered=$(helm template test-release "$CHART_DIR" -f "$VALUES_FILE")
configmap='select(.kind == "ConfigMap" and has("data") and (.data | has("control.toml")))'

if [ -z "$(yq -r "$configmap | .metadata.name" <<< "$rendered")" ]; then
  echo "FAIL: control.toml not found in rendered ConfigMap"
  exit 1
fi

output=$(yq -r "$configmap | .data[\"control.toml\"]" <<< "$rendered")

if [ -z "$2" ]; then
  echo "$output"
else
  echo "$output" > "$2"
fi
