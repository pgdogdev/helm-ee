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

output=$(helm template test-release "$CHART_DIR" -f "$VALUES_FILE" \
  | yq -r 'select(.kind == "ConfigMap" and has("data") and .data["control.toml"]) | .data["control.toml"]')

if [ -z "$output" ]; then
  echo "FAIL: control.toml not found in rendered ConfigMap"
  exit 1
fi

if [ -z "$2" ]; then
  echo "$output"
else
  echo "$output" > "$2"
fi
