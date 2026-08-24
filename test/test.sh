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
echo "==> Verifying external Redis rendering..."
external_render=$(helm template test-release "$CHART_DIR" -f "$TEST_DIR/values-redis-external.yaml")
if grep -q 'app.kubernetes.io/component: redis' <<< "$external_render"; then
  echo "chart-managed Redis resources rendered while redis.enabled=false" >&2
  exit 1
fi
grep -A1 -- '- name: REDIS_URL' <<< "$external_render" | grep -q 'redis://external-redis.example.com:6379'

echo ""
echo "==> Verifying configurable Redis image..."
image_render=$(helm template test-release "$CHART_DIR" -f "$TEST_DIR/values-redis-image.yaml")
grep -q 'image: "registry.example.com/platform/redis:8-alpine"' <<< "$image_render"
grep -q 'imagePullPolicy: Always' <<< "$image_render"
grep -q 'name: registry-credentials' <<< "$image_render"

echo ""
echo "==> All chart tests passed!"
