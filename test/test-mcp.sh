#!/bin/bash
set -eo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHART_DIR="$TEST_DIR/.."

mcp_config() {
  helm template test-release "$CHART_DIR" --show-only templates/configmap.yaml "$@" \
    | yq -r '.data["control.toml"]'
}

echo "==> Verifying MCP configuration..."
default_config=$(mcp_config)
if grep -q '^\[mcp\]$' <<< "$default_config"; then
  echo "MCP configuration rendered with default values" >&2
  exit 1
fi

for raft in false true; do
  enabled_config=$(mcp_config -f "$TEST_DIR/values-mcp.yaml" --set "raft.enabled=$raft")
  grep -q '^\[mcp\]$' <<< "$enabled_config"
  grep -q '^enabled = true$' <<< "$enabled_config"
  grep -Fqx 'tokens = ["test-mcp-token", "test-mcp._~+/=token"]' <<< "$enabled_config"

  empty_config=$(mcp_config -f "$TEST_DIR/values-mcp.yaml" --set "raft.enabled=$raft" \
    --set-json 'control.config.mcp.tokens=[]')
  grep -q '^\[mcp\]$' <<< "$empty_config"
  grep -q '^enabled = true$' <<< "$empty_config"
  grep -Fqx 'tokens = []' <<< "$empty_config"

  omitted_config=$(mcp_config --set control.config.mcp.enabled=true --set "raft.enabled=$raft")
  grep -q '^\[mcp\]$' <<< "$omitted_config"
  grep -q '^enabled = true$' <<< "$omitted_config"
  if grep -q '^tokens = ' <<< "$omitted_config"; then
    echo "MCP tokens rendered when omitted from values" >&2
    exit 1
  fi

  secret_render=$(helm template test-release "$CHART_DIR" -f "$TEST_DIR/values-secrets.yaml" \
    --set "raft.enabled=$raft")
  secret_ref=$(yq -o=json -I=0 'select(.kind == "Deployment" or .kind == "StatefulSet") | .spec.template.spec.containers[] | select(.name == "control") | .env[] | select(.name == "MCP_TOKENS") | .valueFrom.secretKeyRef' <<< "$secret_render")
  if [ "$secret_ref" != '{"name":"control-secrets","key":"mcp-tokens"}' ]; then
    echo "MCP_TOKENS does not reference the configured Secret: $secret_ref" >&2
    exit 1
  fi
  secret_config=$(mcp_config -f "$TEST_DIR/values-secrets.yaml" --set "raft.enabled=$raft")
  grep -q '^\[mcp\]$' <<< "$secret_config"
  if grep -q '^tokens = ' <<< "$secret_config"; then
    echo "Rendered tokens would override MCP_TOKENS from the Secret" >&2
    exit 1
  fi
done

if helm template test-release "$CHART_DIR" -f "$TEST_DIR/values-secrets.yaml" \
  --set control.config.mcp.secret.name= >/dev/null 2>&1; then
  echo "MCP Secret reference rendered without a Secret name" >&2
  exit 1
fi

disabled_config=$(mcp_config -f "$TEST_DIR/values-mcp.yaml" \
  --set control.config.mcp.enabled=false --set-json 'control.config.mcp.tokens=[]')
grep -q '^\[mcp\]$' <<< "$disabled_config"
grep -q '^enabled = false$' <<< "$disabled_config"
grep -Fqx 'tokens = []' <<< "$disabled_config"

echo "==> MCP configuration tests passed!"
