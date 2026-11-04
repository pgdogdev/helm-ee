#!/bin/bash
set -eo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHART_DIR="$TEST_DIR/.."

echo "==> Linting Helm chart..."
helm lint "$CHART_DIR"

for values_file in "$TEST_DIR"/values-*.yaml; do
  name=$(basename "$values_file" .yaml | sed 's/values-//')
  echo ""
  echo "==> Templating and validating $name..."
  helm template test-release "$CHART_DIR" -f "$values_file" | kubeconform -strict -ignore-missing-schemas -summary
done

echo ""
echo "==> Verifying query alert settings..."
full_render=$(helm template test-release "$CHART_DIR" -f "$TEST_DIR/values-full.yaml")
grep -q '^    query_plans_limit = 75$' <<< "$full_render"
grep -q '^    slow_queries_threshold = 2500$' <<< "$full_render"
grep -q '^    slow_queries = true$' <<< "$full_render"

echo ""
echo "==> All chart tests passed!"
