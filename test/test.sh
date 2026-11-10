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
echo "==> Verifying an existing ServiceAccount without RBAC..."
control_sa() {
  helm template test-release "$CHART_DIR" "$@" \
    | yq -o=json -I=0 'select(.kind == "Deployment" and .metadata.name == "test-release-control") | .spec.template.spec | {"sa": .serviceAccountName, "automount": .automountServiceAccountToken}'
}
sa_render=$(helm template test-release "$CHART_DIR" -f "$TEST_DIR/values-existing-service-account.yaml")
if [ "$(control_sa -f "$TEST_DIR/values-existing-service-account.yaml")" != '{"sa":"pgdog-control-aws","automount":null}' ]; then
  echo "control pod does not run as the existing ServiceAccount, or overrides its token setting" >&2
  exit 1
fi
if grep -qE '^kind: (ServiceAccount|ClusterRole|ClusterRoleBinding)$' <<< "$sa_render"; then
  echo "RBAC resources rendered while control.rbac.create=false" >&2
  exit 1
fi
# Opt-in only: without existingServiceAccount, create=false keeps the default SA and ignores roleArn.
if [ "$(control_sa --set control.rbac.create=false --set control.rbac.serviceAccountName=foo --set control.aws.roleArn=arn:aws:iam::123456789012:role/x)" != '{"sa":null,"automount":false}' ]; then
  echo "create=false without existingServiceAccount changed the control pod's ServiceAccount" >&2
  exit 1
fi
for conflict in "control.rbac.create=true" "control.aws.roleArn=arn:aws:iam::123456789012:role/x"; do
  if helm template test-release "$CHART_DIR" -f "$TEST_DIR/values-existing-service-account.yaml" --set "$conflict" >/dev/null 2>&1; then
    echo "existingServiceAccount rendered with $conflict" >&2
    exit 1
  fi
done

echo ""
echo "==> Verifying control pod annotations..."
annotations=$(helm template test-release "$CHART_DIR" -f "$TEST_DIR/values-pod-annotations.yaml" \
  | yq -o=json -I=0 'select(.kind == "Deployment" and .metadata.name == "test-release-control") | .spec.template.metadata.annotations | with_entries(select(.key | test("^checksum/") | not))')
if [ "$annotations" != '{"meta.helm.sh/release-name":"test-release","meta.helm.sh/release-namespace":"default","karpenter.sh/do-not-disrupt":"24h"}' ]; then
  echo "control.podAnnotations not rendered on the control pods: $annotations" >&2
  exit 1
fi
raft_annotation=$(helm template test-release "$CHART_DIR" -f "$TEST_DIR/values-raft.yaml" -f "$TEST_DIR/values-pod-annotations.yaml" \
  | yq -r 'select(.kind == "StatefulSet") | .spec.template.metadata.annotations."karpenter.sh/do-not-disrupt"')
if [ "$raft_annotation" != "24h" ]; then
  echo "control.podAnnotations not rendered on the raft StatefulSet pods: $raft_annotation" >&2
  exit 1
fi

echo ""
echo "==> All chart tests passed!"
