#!/bin/bash
set -eo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHART_DIR="$TEST_DIR/.."

echo "==> Linting Helm chart..."
helm lint "$CHART_DIR"

for values_file in "$TEST_DIR"/values-*.yaml; do
  name=$(basename "$values_file" .yaml | sed 's/values-//')
  echo ""
  echo "==> Rendering $name..."
  helm template test-release "$CHART_DIR" -f "$values_file" > /dev/null
done

echo ""
echo "==> Verifying query alert settings..."
full_render=$(helm template test-release "$CHART_DIR" -f "$TEST_DIR/values-full.yaml")
grep -q '^    query_plans_limit = 75$' <<< "$full_render"
grep -q '^    slow_queries_threshold = 2500$' <<< "$full_render"
grep -q '^    slow_queries = true$' <<< "$full_render"
grep -q '^    checkout_timeouts = 1$' <<< "$full_render"

echo ""
echo "==> Verifying external Redis rendering..."
external_render=$(helm template test-release "$CHART_DIR" -f "$TEST_DIR/values-redis-external.yaml")
if grep -q 'app.kubernetes.io/component: redis' <<< "$external_render"; then
  echo "chart-managed Redis resources rendered while redis.enabled=false" >&2
  exit 1
fi
if grep -q -- '- name: REDIS_URL' <<< "$external_render"; then
  echo "REDIS_URL environment variable rendered, but the app only reads control.toml" >&2
  exit 1
fi
grep -A1 '^    \[redis\]$' <<< "$external_render" | grep -q 'url = "redis://external-redis.example.com:6379"'

echo ""
echo "==> Verifying configurable Redis image..."
image_render=$(helm template test-release "$CHART_DIR" -f "$TEST_DIR/values-redis-image.yaml")
grep -q 'image: "registry.example.com/platform/redis:8-alpine"' <<< "$image_render"
grep -q 'imagePullPolicy: Always' <<< "$image_render"
grep -q 'name: registry-credentials' <<< "$image_render"

echo ""
echo "==> All chart tests passed!"
