#!/usr/bin/env bash
#
# install2.sh - read-only prerequisite checker for the PgDog EE Control Plane.
#
# This script is intentionally safe for `curl | bash`: it only inspects local
# tools, Kubernetes resources, and AWS state. It does not create, update, or
# print commands that create or update resources.
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults / State
# ---------------------------------------------------------------------------
RELEASE="pgdog-control"
NAMESPACE="default"
MODE=""
MODE_FROM_FLAG=0
HOST=""
VALUES_FILE=""
AWS_REGION=""
AWS_CLUSTER=""
AWS_ROLE_ARN=""
AWS_ROLE_NAME=""
AWS_CERT_ARN=""
GATEWAY_NAME=""
GATEWAY_NAMESPACE=""
GATEWAY_SECTION=""
CHECK_TARGET="all"
IAM_MODE=""

STEP=0
FAILURES=0
WARNINGS=0
CLUSTER_OK=1
CLUSTER_AUTH_OK=1
ENVOY_GATEWAY_CLASSES=""
AWS_ACCOUNT_ID=""
OIDC_HOST=""
IAM_OIDC_PROVIDER_EXISTS=0
LOADING_ACTIVE=0
IAM_ROLE_DOC=""
AWS_ACCOUNT_ID_FROM_FLAG=0
OIDC_HOST_FROM_FLAG=0

# ---------------------------------------------------------------------------
# UI
# ---------------------------------------------------------------------------
if [[ -t 1 ]] && command -v tput >/dev/null 2>&1 && [[ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]]; then
  BOLD=$(tput bold); RESET=$(tput sgr0); DIM=$(tput dim)
  RED=$(tput setaf 1); GREEN=$(tput setaf 2); YELLOW=$(tput setaf 3)
  BLUE=$(tput setaf 4); CYAN=$(tput setaf 6)
else
  BOLD=""; RESET=""; DIM=""; RED=""; GREEN=""; YELLOW=""; BLUE=""; CYAN=""
fi

CHECK="OK"
CROSS="FAIL"
WARN_SYM="WARN"

heading() {
  clear_loading
  STEP=$((STEP + 1))
  printf "\n${BLUE}${BOLD}Step %d${RESET}  ${BOLD}%s${RESET}\n" "$STEP" "$1"
}

clear_loading() {
  if (( LOADING_ACTIVE )) && [[ -t 1 ]]; then
    printf "\r\033[K"
  fi
  LOADING_ACTIVE=0
}

loading() {
  if [[ -t 1 ]]; then
    printf "  ${BLUE}%-5s${RESET} %-28s ${DIM}checking...${RESET}\r" "..." "$1"
    LOADING_ACTIVE=1
  else
    printf "  ${BLUE}%-5s${RESET} %-28s ${DIM}checking...${RESET}\n" "..." "$1"
  fi
}

row() {
  clear_loading
  local status=$1 name=$2 detail=${3:-}
  local color symbol
  case "$status" in
    ok) color=$GREEN; symbol=$CHECK ;;
    warn) color=$YELLOW; symbol=$WARN_SYM; WARNINGS=$((WARNINGS + 1)) ;;
    fail) color=$RED; symbol=$CROSS; FAILURES=$((FAILURES + 1)) ;;
    *) color=""; symbol="$status" ;;
  esac
  printf "  ${color}%-5s${RESET} %-28s ${DIM}%s${RESET}\n" "$symbol" "$name" "$detail"
}

info() {
  clear_loading
  printf "  ${CYAN}INFO ${RESET} %s\n" "$1"
}

input_error() {
  clear_loading
  printf "  ${YELLOW}%-5s${RESET} %s\n" "WARN" "$1"
}

die() {
  clear_loading
  printf "\n${RED}${BOLD}Aborting:${RESET} %s\n" "$1" >&2
  exit 2
}

# ---------------------------------------------------------------------------
# Helpers / Validation
# ---------------------------------------------------------------------------
have() {
  case " ${FAKE_MISSING:-} " in *" $1 "*) return 1 ;; esac
  command -v "$1" >/dev/null 2>&1
}

version_line() {
  local cmd=$1 args=$2
  $cmd $args 2>&1 | head -n1 | cut -c1-70 || true
}

valid_namespace() {
  [[ ${#1} -le 63 && "$1" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]]
}

valid_mode() {
  case "$1" in nginx|aws|gateway) return 0 ;; *) return 1 ;; esac
}

valid_check_target() {
  case "$1" in all|local|cluster|nginx|aws|gateway|iam|values) return 0 ;; *) return 1 ;; esac
}

valid_iam_mode() {
  case "$1" in check|generate) return 0 ;; *) return 1 ;; esac
}

valid_nonempty() {
  [[ -n "$1" ]]
}

valid_release() {
  valid_namespace "$1"
}

valid_iam_role_ref() {
  [[ "$1" =~ ^arn:aws[^:]*:iam::[0-9]{12}:role/.+ || "$1" =~ ^[A-Za-z0-9+=,.@_/-]+$ ]]
}

mode_label() {
  case "$1" in
    nginx) printf 'ingress-nginx + cert-manager' ;;
    aws) printf 'AWS Load Balancer Controller / ALB' ;;
    gateway) printf 'Gateway API HTTPRoute' ;;
    *) printf 'unknown' ;;
  esac
}

valid_acm_domain() {
  [[ ${#1} -le 253 && "$1" =~ ^(\*\.)?([A-Za-z0-9]([-A-Za-z0-9]{0,61}[A-Za-z0-9])?\.)+[A-Za-z0-9]([-A-Za-z0-9]{0,61}[A-Za-z0-9])?$ ]]
}

crd_exists() {
  kubectl get crd "$1" >/dev/null 2>&1
}

is_kube_auth_error() {
  [[ "$1" =~ [Ff]orbidden|[Uu]nauthorized|[Pp]ermission[[:space:]]denied|must[[:space:]]be[[:space:]]logged[[:space:]]in|provide[[:space:]]credentials|You[[:space:]]must[[:space:]]be[[:space:]]logged[[:space:]]in ]]
}

resolve_hostname() {
  local host=$1
  if have getent; then
    getent ahosts "$host" 2>/dev/null | awk '{print $1}' | sort -u | paste -sd ', ' -
  elif have dig; then
    dig +short "$host" A "$host" AAAA 2>/dev/null | sed '/^$/d' | sort -u | paste -sd ', ' -
  elif have host; then
    host "$host" 2>/dev/null | awk '/has address|has IPv6 address/ {print $NF}' | sort -u | paste -sd ', ' -
  elif have nslookup; then
    nslookup "$host" 2>/dev/null | awk '/^Address: / {print $2}' | sort -u | paste -sd ', ' -
  else
    return 2
  fi
}

check_hostname_dns() {
  if [[ -n "$HOST" ]]; then
    local addresses
    loading "hostname DNS"
    addresses=$(resolve_hostname "$HOST" || true)
    if [[ -n "$addresses" ]]; then
      row ok "hostname DNS" "$HOST resolves to $addresses"
    elif have getent || have dig || have host || have nslookup; then
      row warn "hostname DNS" "$HOST does not resolve"
    else
      row warn "hostname DNS" "no local DNS lookup tool available"
    fi
  elif [[ -n "$VALUES_FILE" ]]; then
    row warn "hostname DNS" "not checked; pass --host to verify DNS"
  else
    if ensure_stdin_tty; then
      prompt_until "External hostname" "" valid_acm_domain "Enter a valid DNS name, e.g. control.example.com."
      HOST="$PROMPT_VALUE"
      check_hostname_dns
    else
      row fail "hostname DNS" "missing --host and no terminal is available to ask"
    fi
  fi
}

yaml_scalar() {
  local value=$1
  if [[ -z "$value" ]]; then
    printf '""'
    return 0
  fi
  if [[ "$value" =~ ^[A-Za-z0-9._/@:+,=-]+$ ]] \
    && [[ ! "$value" =~ ^[-+]?[0-9]+([.][0-9]+)?$ ]] \
    && [[ ! "$value" =~ ^([Tt]rue|[Ff]alse|[Yy]es|[Nn]o|[Oo]n|[Oo]ff|[Nn]ull|NULL|~)$ ]]; then
    printf '%s' "$value"
    return 0
  fi
  value=${value//\\/\\\\}
  value=${value//\"/\\\"}
  printf '"%s"' "$value"
}

prompt_until() {
  local prompt=$1 default=${2:-} validator=${3:-} invalid=${4:-"Invalid input."}
  local value
  while true; do
    if [[ -n "$default" ]]; then
      printf "  ${YELLOW}?${RESET} %s ${DIM}[%s]${RESET}: " "$prompt" "$default"
    else
      printf "  ${YELLOW}?${RESET} %s: " "$prompt"
    fi
    read -r value
    value=${value:-$default}
    if [[ -z "$validator" ]] || "$validator" "$value"; then
      PROMPT_VALUE="$value"
      return 0
    fi
    input_error "$invalid"
  done
}

ensure_stdin_tty() {
  if [[ -t 0 ]]; then
    return 0
  fi
  if (exec </dev/tty) 2>/dev/null; then
    exec </dev/tty
    return 0
  fi
  return 1
}

# ---------------------------------------------------------------------------
# Args
# ---------------------------------------------------------------------------
usage() {
  cat <<EOF
PgDog EE Control Plane prerequisite checker

Usage: $0 [options]
  -r, --release NAME       Helm release name              (default: pgdog-control)
  -n, --namespace NS       Target namespace               (default: default)
  -m, --mode MODE          Ingress mode: nginx | aws | gateway
      --check CHECK        Check to run: all | local | cluster | nginx | aws | gateway | iam | values
      --iam-mode MODE      IAM mode: check | generate
      --host HOST          External hostname
  -f, --values FILE        values.yaml intended for install
      --gateway-name NAME  Gateway name for gateway mode
      --gateway-namespace NS
                            Gateway namespace for gateway mode
      --gateway-section NAME
                            Gateway listener sectionName for gateway mode
      --aws-cluster NAME   EKS cluster name for AWS checks
      --aws-region REGION  AWS region for AWS checks
      --aws-role-arn ARN   Existing IAM role ARN expected for IRSA
      --aws-role-name NAME IAM role name expected for IRSA
      --aws-account-id ID  AWS account ID for generated IAM trust policy
      --oidc-host HOST     EKS OIDC issuer host for generated IAM trust policy
      --acm-cert-arn ARN   ACM certificate ARN expected for AWS ALB HTTPS
  -h, --help               Show this help

This checker is read-only. It reports missing or misconfigured dependencies
and does not print installation commands.
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -r|--release) RELEASE=${2:-}; shift 2 ;;
      -n|--namespace) NAMESPACE=${2:-}; shift 2 ;;
      -m|--mode) MODE=${2:-}; MODE_FROM_FLAG=1; shift 2 ;;
      --check) CHECK_TARGET=${2:-}; shift 2 ;;
      --iam-mode) IAM_MODE=${2:-}; shift 2 ;;
      --host) HOST=${2:-}; shift 2 ;;
      -f|--values) VALUES_FILE=${2:-}; shift 2 ;;
      --gateway-name) GATEWAY_NAME=${2:-}; shift 2 ;;
      --gateway-namespace) GATEWAY_NAMESPACE=${2:-}; shift 2 ;;
      --gateway-section) GATEWAY_SECTION=${2:-}; shift 2 ;;
      --aws-cluster) AWS_CLUSTER=${2:-}; shift 2 ;;
      --aws-region) AWS_REGION=${2:-}; shift 2 ;;
      --aws-role-arn) AWS_ROLE_ARN=${2:-}; shift 2 ;;
      --aws-role-name) AWS_ROLE_NAME=${2:-}; shift 2 ;;
      --aws-account-id) AWS_ACCOUNT_ID=${2:-}; AWS_ACCOUNT_ID_FROM_FLAG=1; shift 2 ;;
      --oidc-host) OIDC_HOST=${2:-}; OIDC_HOST_FROM_FLAG=1; shift 2 ;;
      --acm-cert-arn) AWS_CERT_ARN=${2:-}; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) die "Unknown option: $1" ;;
    esac
  done

  valid_namespace "$NAMESPACE" || die "Invalid --namespace: $NAMESPACE"
  if (( MODE_FROM_FLAG )) && ! valid_mode "$MODE"; then
    die "Invalid --mode: $MODE"
  fi
  if ! valid_check_target "$CHECK_TARGET"; then
    die "Invalid --check: $CHECK_TARGET"
  fi
  if [[ -n "$IAM_MODE" ]] && ! valid_iam_mode "$IAM_MODE"; then
    die "Invalid --iam-mode: $IAM_MODE"
  fi
  if [[ -n "$HOST" ]] && ! valid_acm_domain "$HOST"; then
    die "Invalid --host: $HOST"
  fi
  if [[ -n "$VALUES_FILE" && ! -f "$VALUES_FILE" ]]; then
    die "Values file not found: $VALUES_FILE"
  fi
}

# ---------------------------------------------------------------------------
# Local Checks
# ---------------------------------------------------------------------------
check_local_tool() {
  local label=$1 cmd=$2 args=$3 required=$4 note=$5
  loading "$label"
  if have "$cmd"; then
    row ok "$label" "$(version_line "$cmd" "$args")"
  elif (( required )); then
    row fail "$label" "missing; $note"
  else
    row warn "$label" "missing; $note"
  fi
}

check_local_deps() {
  heading "Local Dependencies"
  check_local_tool "kubectl" kubectl "version --client" 1 "required to inspect the cluster"
  check_local_tool "jq" jq "--version" 1 "required to inspect IAM policies"
  check_local_tool "helm" helm "version --short" 0 "used for installing the chart"
  check_local_tool "aws" aws "--version" 0 "required for AWS, ACM, Route53, and IRSA diagnostics"
}

check_iam_local_deps() {
  heading "Local Dependencies"
  check_local_tool "aws" aws "--version" 1 "required to inspect IAM roles and policies"
  check_local_tool "jq" jq "--version" 1 "required to inspect IAM policies"
  check_local_tool "kubectl" kubectl "version --client" 0 "used to infer EKS cluster context when available"
}

# ---------------------------------------------------------------------------
# Kubernetes Discovery
# ---------------------------------------------------------------------------
envoy_gateway_classes() {
  kubectl get gatewayclasses.gateway.networking.k8s.io \
    -o jsonpath='{range .items[?(@.spec.controllerName=="gateway.envoyproxy.io/gatewayclass-controller")]}{.metadata.name}{" "}{end}' 2>/dev/null || true
}

envoy_gateway_deployment_exists() {
  [[ -n "$(kubectl get deploy -A -l app.kubernetes.io/name=envoy-gateway --no-headers 2>/dev/null || true)" ]] \
    || kubectl -n envoy-gateway-system get deploy envoy-gateway >/dev/null 2>&1
}

first_gateway() {
  kubectl get gateways.gateway.networking.k8s.io -A \
    -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.metadata.name}{" "}{.spec.gatewayClassName}{"\n"}{end}' 2>/dev/null \
    | head -n1 || true
}

first_envoy_gateway() {
  local classes=$1 ns name class
  [[ -n "$classes" ]] || return 0
  while read -r ns name class; do
    [[ -n "$ns" && -n "$name" && -n "$class" ]] || continue
    case " $classes " in
      *" $class "*) printf '%s %s %s\n' "$ns" "$name" "$class"; return 0 ;;
    esac
  done < <(kubectl get gateways.gateway.networking.k8s.io -A \
    -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.metadata.name}{" "}{.spec.gatewayClassName}{"\n"}{end}' 2>/dev/null || true)
}

gateway_https_section() {
  local ns=$1 name=$2
  kubectl -n "$ns" get gateway "$name" \
    -o jsonpath='{range .spec.listeners[?(@.protocol=="HTTPS")]}{.name}{" "}{end}' 2>/dev/null \
    | awk '{print $1}'
}

check_cluster_access() {
  heading "Cluster Access"

  if ! have kubectl; then
    CLUSTER_OK=0
    row fail "kube API" "kubectl is missing"
    return 0
  fi

  local cluster_err=""
  loading "kube API"
  if cluster_err=$(kubectl cluster-info 2>&1 >/dev/null); then
    row ok "kube API" "context: $(kubectl config current-context 2>/dev/null || echo '?')"
  else
    CLUSTER_OK=0
    if is_kube_auth_error "$cluster_err"; then
      CLUSTER_AUTH_OK=0
      row fail "kube API auth" "current identity is not authorized"
    else
      row fail "kube API" "cluster is not reachable"
    fi
    return 0
  fi

}

choose_mode() {
  if (( MODE_FROM_FLAG )); then
    return 0
  fi

  local default choice
  default="nginx"

  if [[ ! -t 0 ]]; then
    if (exec </dev/tty) 2>/dev/null; then
      exec </dev/tty
    else
      heading "Configuration"
      row fail "mode" "missing --mode and no terminal is available to ask"
      return 0
    fi
  fi

  heading "Configuration"
  printf "  Choose ingress mode ${DIM}[default: %s - %s]${RESET}\n" "$default" "$(mode_label "$default")"
  printf "    ${BOLD}1${RESET}  nginx    ${DIM}%s${RESET}\n" "$(mode_label nginx)"
  printf "    ${BOLD}2${RESET}  aws      ${DIM}%s${RESET}\n" "$(mode_label aws)"
  printf "    ${BOLD}3${RESET}  gateway  ${DIM}%s${RESET}\n" "$(mode_label gateway)"

  while true; do
    printf "  ${YELLOW}?${RESET} Mode [1/2/3]: "
    read -r choice
    choice=${choice:-$default}
    case "$choice" in
      1|nginx) MODE="nginx"; return 0 ;;
      2|aws) MODE="aws"; return 0 ;;
      3|gateway) MODE="gateway"; return 0 ;;
      *) row warn "mode" "enter 1, 2, 3, nginx, aws, or gateway" ;;
    esac
  done
}

# ---------------------------------------------------------------------------
# AWS Discovery
# ---------------------------------------------------------------------------
derive_eks_from_context() {
  local ctx cluster_ref ref
  ctx=$(kubectl config current-context 2>/dev/null || true)
  cluster_ref=$(kubectl config view --minify -o jsonpath='{.contexts[0].context.cluster}' 2>/dev/null || true)
  for ref in "$ctx" "$cluster_ref"; do
    if [[ "$ref" =~ ^arn:aws[^:]*:eks:([^:]+):[0-9]+:cluster/(.+)$ ]]; then
      [[ -z "$AWS_REGION" ]] && AWS_REGION="${BASH_REMATCH[1]}"
      [[ -z "$AWS_CLUSTER" ]] && AWS_CLUSTER="${BASH_REMATCH[2]}"
      return 0
    fi
  done
  return 1
}

discover_eks_oidc() {
  IAM_OIDC_PROVIDER_EXISTS=0
  [[ -n "$AWS_CLUSTER" && -n "$AWS_REGION" ]] || return 1
  have aws || return 1

  if (( AWS_ACCOUNT_ID_FROM_FLAG == 0 )); then
    AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null || true)
  fi
  if (( OIDC_HOST_FROM_FLAG == 0 )); then
    OIDC_HOST=$(aws eks describe-cluster --name "$AWS_CLUSTER" --region "$AWS_REGION" \
      --query 'cluster.identity.oidc.issuer' --output text 2>/dev/null | sed 's|^https://||' || true)
  fi

  [[ -n "$AWS_ACCOUNT_ID" && -n "$OIDC_HOST" && "$OIDC_HOST" != "None" ]] || return 1

  local provider_arn="arn:aws:iam::${AWS_ACCOUNT_ID}:oidc-provider/${OIDC_HOST}"
  if aws iam get-open-id-connect-provider --open-id-connect-provider-arn "$provider_arn" >/dev/null 2>&1; then
    IAM_OIDC_PROVIDER_EXISTS=1
  fi
  return 0
}

ensure_iam_generation_context() {
  if [[ -n "$AWS_ACCOUNT_ID" && -n "$OIDC_HOST" && "$AWS_ACCOUNT_ID" != "None" && "$OIDC_HOST" != "None" ]]; then
    return 0
  fi
  if ensure_stdin_tty; then
    [[ -n "$AWS_ACCOUNT_ID" && "$AWS_ACCOUNT_ID" != "None" ]] || {
      prompt_until "AWS account ID" "" valid_nonempty "AWS account ID is required."
      AWS_ACCOUNT_ID="$PROMPT_VALUE"
    }
    [[ -n "$OIDC_HOST" && "$OIDC_HOST" != "None" ]] || {
      prompt_until "EKS OIDC issuer host" "" valid_nonempty "OIDC issuer host is required."
      OIDC_HOST="${PROMPT_VALUE#https://}"
    }
    return 0
  fi
  row fail "IAM generation context" "missing AWS account ID or OIDC host"
  return 1
}

check_acm_cert() {
  [[ "$MODE" == "aws" ]] || return 0

  if [[ -z "$AWS_CERT_ARN" ]]; then
    row warn "ACM certificate" "no --acm-cert-arn supplied; AWS ALB will be HTTP-only unless values set one"
    info "For HTTPS, create an ACM certificate for ${HOST:-the ingress host} with DNS validation, wait until it is ISSUED, then rerun with --acm-cert-arn."
    return 0
  fi
  if ! have aws; then
    row warn "ACM certificate" "cannot verify certificate ARN because AWS CLI is missing"
    info "Verify the ACM certificate is DNS-validated and ISSUED before using it with the AWS ALB."
    return 0
  fi

  local region="${AWS_REGION:-}"
  if [[ -z "$region" && "$AWS_CERT_ARN" =~ ^arn:aws[^:]*:acm:([^:]+): ]]; then
    region="${BASH_REMATCH[1]}"
  fi
  if [[ -z "$region" ]]; then
    row warn "ACM certificate" "cannot infer region for certificate verification"
    info "Use an ACM certificate in the same AWS region as the ALB, and pass --aws-region or a region-qualified certificate ARN."
    return 0
  fi

  local status
  loading "ACM certificate"
  status=$(aws acm describe-certificate \
    --region "$region" \
    --certificate-arn "$AWS_CERT_ARN" \
    --query 'Certificate.Status' \
    --output text 2>/dev/null || true)
  if [[ "$status" == "ISSUED" ]]; then
    row ok "ACM certificate" "ISSUED in $region"
    check_acm_cert_host "$region"
  elif [[ -n "$status" && "$status" != "None" ]]; then
    row fail "ACM certificate" "status is $status"
    info "Complete DNS validation for the ACM certificate and wait until ACM reports ISSUED, then rerun this check."
    check_acm_cert_host "$region"
  else
    row fail "ACM certificate" "not found or not readable in $region"
    info "Create or locate an ACM certificate for ${HOST:-the ingress host} in $region using DNS validation, then rerun with --acm-cert-arn."
  fi
}

host_matches_cert_name() {
  local host=${1%.} name=${2%.}
  host=${host,,}
  name=${name,,}
  if [[ "$name" == "$host" ]]; then
    return 0
  fi
  if [[ "$name" == \*.* ]]; then
    local suffix="${name#*.}"
    [[ "$host" == *".${suffix}" && "${host%.${suffix}}" != *.* ]]
  else
    return 1
  fi
}

check_acm_cert_host() {
  [[ -n "$HOST" ]] || return 0
  local region=$1 names name matched=0
  loading "ACM host coverage"
  names=$(aws acm describe-certificate \
    --region "$region" \
    --certificate-arn "$AWS_CERT_ARN" \
    --query 'Certificate.[DomainName,SubjectAlternativeNames[]]' \
    --output text 2>/dev/null | tr '\t' '\n' | sed '/^$/d' | sort -u || true)
  while read -r name; do
    [[ -n "$name" ]] || continue
    if host_matches_cert_name "$HOST" "$name"; then
      matched=1
      break
    fi
  done <<< "$names"

  if (( matched )); then
    row ok "ACM host coverage" "$HOST covered by $name"
  elif [[ -n "$names" ]]; then
    row warn "ACM host coverage" "$HOST not covered by certificate names: $(echo "$names" | paste -sd ', ' -)"
    info "Request or select an ACM certificate whose domain name or SAN covers $HOST, validate it with DNS, then rerun with --acm-cert-arn."
  else
    row warn "ACM host coverage" "could not read certificate domain names"
  fi
}

role_name_from_ref() {
  local ref=$1
  if [[ "$ref" =~ ^arn:aws[^:]*:iam::[0-9]{12}:role/(.+)$ ]]; then
    printf '%s' "${BASH_REMATCH[1]##*/}"
  else
    printf '%s' "$ref"
  fi
}

required_iam_actions() {
  printf '%s\n' \
    "rds:DescribeDBClusters" \
    "rds:DescribeDBInstances" \
    "rds:DescribeDBClusterParameters" \
    "rds:DescribeDBParameters" \
    "cloudwatch:GetMetricData" \
    "ec2:DescribeInstanceTypes"
}

role_policy_actions() {
  local role=$1 policy version arn doc
  while read -r policy; do
    [[ -n "$policy" && "$policy" != "None" ]] || continue
    doc=$(aws iam get-role-policy \
      --role-name "$role" \
      --policy-name "$policy" \
      --query "PolicyDocument" \
      --output json 2>/dev/null || true)
    policy_actions_from_json "$doc"
  done < <(aws iam list-role-policies --role-name "$role" --query 'PolicyNames[]' --output text 2>/dev/null | tr '\t' '\n')

  while read -r arn; do
    [[ -n "$arn" && "$arn" != "None" ]] || continue
    version=$(aws iam get-policy --policy-arn "$arn" --query 'Policy.DefaultVersionId' --output text 2>/dev/null || true)
    [[ -n "$version" && "$version" != "None" ]] || continue
    doc=$(aws iam get-policy-version \
      --policy-arn "$arn" \
      --version-id "$version" \
      --query "PolicyVersion.Document" \
      --output json 2>/dev/null || true)
    policy_actions_from_json "$doc"
  done < <(aws iam list-attached-role-policies --role-name "$role" --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null | tr '\t' '\n')
}

policy_actions_from_json() {
  local doc=${1:-}
  [[ -n "$doc" && "$doc" != "null" ]] || return 0
  jq -r '
    def listify:
      if type == "array" then .[] else . end;
    [.Statement] | flatten | .[]?
    | select((.Effect // "") == "Allow")
    | (.Action // empty | listify)
    | select(type == "string")
  ' <<< "$doc" 2>/dev/null || true
}

action_allowed() {
  local required=${1,,} allowed raw
  while read -r raw; do
    for allowed in $raw; do
      allowed=${allowed,,}
      if [[ "$allowed" == "*" || "$required" == $allowed ]]; then
        return 0
      fi
    done
  done
  return 1
}

prompt_iam_inputs() {
  if ! ensure_stdin_tty; then
    if [[ "$IAM_MODE" == "generate" ]]; then
      return 0
    fi
    [[ -n "$AWS_ROLE_ARN" || -n "$AWS_ROLE_NAME" ]] && return 0
    row fail "IAM role" "missing --aws-role-arn or --aws-role-name and no terminal is available to ask"
    return 1
  fi

  if [[ -z "$IAM_MODE" ]]; then
    local choice
    printf "  Choose IAM check mode ${DIM}[default: check]${RESET}\n"
    printf "    ${BOLD}1${RESET}  check      ${DIM}validate an existing role${RESET}\n"
    printf "    ${BOLD}2${RESET}  generate   ${DIM}print trust and permissions JSON${RESET}\n"
    while true; do
      printf "  ${YELLOW}?${RESET} IAM mode [1/2]: "
      read -r choice
      choice=${choice:-check}
      case "$choice" in
        1|check) IAM_MODE="check"; break ;;
        2|generate) IAM_MODE="generate"; break ;;
        *) input_error "Enter 1, 2, check, or generate." ;;
      esac
    done
  fi

  prompt_until "Release name for IAM trust" "$RELEASE" valid_release "Use a valid Helm release name."
  RELEASE="$PROMPT_VALUE"
  prompt_until "Namespace for IAM trust" "$NAMESPACE" valid_namespace "Use a valid Kubernetes namespace."
  NAMESPACE="$PROMPT_VALUE"
  if [[ "$IAM_MODE" == "check" && -z "$AWS_ROLE_ARN" && -z "$AWS_ROLE_NAME" ]]; then
    prompt_until "IAM role name or ARN" "" valid_iam_role_ref "Enter an IAM role name or role ARN."
    if [[ "$PROMPT_VALUE" =~ ^arn: ]]; then
      AWS_ROLE_ARN="$PROMPT_VALUE"
    else
      AWS_ROLE_NAME="$PROMPT_VALUE"
    fi
  fi
  return 0
}

check_iam_trust_policy() {
  local expected_sub="system:serviceaccount:${NAMESPACE}:${RELEASE}-control"
  local issuers aud_ok

  if ! jq -e '
    def listify:
      if type == "array" then .[] else . end;
    [.Statement] | flatten | any(.[];
      (.Action // empty | listify | ascii_downcase) == "sts:assumerolewithwebidentity"
    )
  ' <<< "$IAM_ROLE_DOC" >/dev/null 2>&1; then
    row fail "IAM trust policy" "missing sts:AssumeRoleWithWebIdentity"
    return 0
  fi

  issuers=$(jq -r --arg sub "$expected_sub" '
    def string_equals:
      (.Condition.StringEquals // {}) | to_entries[];
    [.Statement] | flatten | .[]?
    | string_equals
    | select((.key | endswith(":sub")) and .value == $sub)
    | .key | sub(":sub$"; "")
  ' <<< "$IAM_ROLE_DOC" 2>/dev/null | sort -u | paste -sd ', ' -)

  if [[ -z "$issuers" ]]; then
    row fail "IAM trust policy" "missing $expected_sub"
    return 0
  fi

  if [[ -n "$OIDC_HOST" ]] && ! grep -Fxq "$OIDC_HOST" <<< "${issuers//, /$'\n'}"; then
    row fail "IAM trust policy" "trusts $expected_sub for $issuers, current issuer is $OIDC_HOST"
    return 0
  fi

  aud_ok=$(jq -r --arg oidc "$OIDC_HOST" '
    if $oidc == "" then
      true
    else
      [.Statement] | flatten | any(.[];
        (.Condition.StringEquals // {})[($oidc + ":aud")] == "sts.amazonaws.com"
      )
    end
  ' <<< "$IAM_ROLE_DOC" 2>/dev/null || printf 'false')

  if [[ "$aud_ok" == "true" ]]; then
    row ok "IAM trust policy" "$expected_sub"
  else
    row fail "IAM trust policy" "missing ${OIDC_HOST}:aud sts.amazonaws.com"
  fi
}

check_iam_permissions() {
  local role=$1 actions missing=() required
  loading "IAM permissions"
  actions=$(role_policy_actions "$role" | tr '\t' '\n' | sed '/^$/d' || true)
  while read -r required; do
    [[ -n "$required" ]] || continue
    if ! action_allowed "$required" <<< "$actions"; then
      missing+=("$required")
    fi
  done < <(required_iam_actions)

  if (( ${#missing[@]} == 0 )); then
    row ok "IAM permissions" "required RDS, CloudWatch, and EC2 actions allowed"
  else
    row fail "IAM permissions" "missing: $(IFS=', '; printf '%s' "${missing[*]}")"
  fi
}

print_iam_policy_json() {
  local expected_sub="system:serviceaccount:${NAMESPACE}:${RELEASE}-control"
  local oidc="${OIDC_HOST:-OIDC_HOST}"
  local account="${AWS_ACCOUNT_ID:-ACCOUNT_ID}"

  heading "IAM Trust Policy"
  jq -n \
    --arg account "$account" \
    --arg oidc "$oidc" \
    --arg sub "$expected_sub" \
    '{
      Version: "2012-10-17",
      Statement: [
        {
          Effect: "Allow",
          Principal: {
            Federated: ("arn:aws:iam::" + $account + ":oidc-provider/" + $oidc)
          },
          Action: "sts:AssumeRoleWithWebIdentity",
          Condition: {
            StringEquals: {
              ($oidc + ":sub"): $sub,
              ($oidc + ":aud"): "sts.amazonaws.com"
            }
          }
        }
      ]
    }'
  printf '\n'

  heading "IAM Permissions Policy"
  jq -n \
    --argjson rds "$(required_iam_actions | awk '/^rds:/ {print}' | jq -R . | jq -s .)" \
    '{
      Version: "2012-10-17",
      Statement: [
        {
          Sid: "RdsTopology",
          Effect: "Allow",
          Action: $rds,
          Resource: "*"
        },
        {
          Sid: "CloudWatchMetrics",
          Effect: "Allow",
          Action: ["cloudwatch:GetMetricData"],
          Resource: "*"
        },
        {
          Sid: "Ec2InstanceTypeSpecs",
          Effect: "Allow",
          Action: ["ec2:DescribeInstanceTypes"],
          Resource: "*"
        }
      ]
    }'
  printf '\n'

  info "After creating the IAM role with these policies, rerun this script with --iam-mode check --aws-role-arn <ROLE_ARN>."
}

check_iam_diagnostics() {
  heading "IAM Diagnostics"

  if ! have aws; then
    row fail "AWS CLI" "missing for IAM role diagnostics"
    return 0
  fi
  if ! have jq; then
    row fail "jq" "missing for IAM policy diagnostics"
    return 0
  fi

  prompt_iam_inputs || return 0

  derive_eks_from_context || true
  if [[ -n "$AWS_CLUSTER" && -n "$AWS_REGION" ]]; then
    row ok "EKS context" "$AWS_CLUSTER ($AWS_REGION)"
    loading "EKS OIDC issuer"
    if discover_eks_oidc; then
      row ok "EKS OIDC issuer" "$OIDC_HOST"
      if (( IAM_OIDC_PROVIDER_EXISTS )); then
        row ok "IAM OIDC provider" "registered in account $AWS_ACCOUNT_ID"
      elif [[ "$IAM_MODE" == "generate" ]]; then
        row warn "IAM OIDC provider" "not registered in account $AWS_ACCOUNT_ID"
      else
        row fail "IAM OIDC provider" "not registered in account $AWS_ACCOUNT_ID"
      fi
    else
      row warn "EKS OIDC issuer" "could not verify issuer/provider"
    fi
  else
    row warn "EKS context" "cluster and region not known"
  fi

  if [[ "$IAM_MODE" == "generate" ]]; then
    ensure_iam_generation_context || return 0
    print_iam_policy_json
    return 0
  fi

  local role_ref role_name role_arn
  role_ref="${AWS_ROLE_ARN:-$AWS_ROLE_NAME}"
  role_name=$(role_name_from_ref "$role_ref")

  loading "IAM role"
  role_arn=$(aws iam get-role --role-name "$role_name" --query 'Role.Arn' --output text 2>/dev/null || true)
  if [[ -n "$role_arn" && "$role_arn" != "None" ]]; then
    AWS_ROLE_ARN="$role_arn"
    row ok "IAM role" "$role_arn exists"
  else
    row fail "IAM role" "$role_ref not found or not readable"
    return 0
  fi

  loading "IAM trust policy"
  IAM_ROLE_DOC=$(aws iam get-role --role-name "$role_name" --query 'Role.AssumeRolePolicyDocument' --output json 2>/dev/null || true)
  check_iam_trust_policy
  check_iam_permissions "$role_name"
}

# ---------------------------------------------------------------------------
# Mode-specific Diagnostics
# ---------------------------------------------------------------------------
check_nginx_mode() {
  heading "Nginx Mode"

  loading "ingress-nginx"
  if kubectl get ingressclass nginx >/dev/null 2>&1 \
    || kubectl -n ingress-nginx get deploy ingress-nginx-controller >/dev/null 2>&1; then
    row ok "ingress-nginx" "detected"
  else
    row fail "ingress-nginx" "controller not detected"
  fi

  loading "cert-manager"
  if crd_exists clusterissuers.cert-manager.io; then
    row ok "cert-manager" "ClusterIssuer CRD present"
    local ready
    loading "ClusterIssuer"
    ready=$(kubectl get clusterissuer letsencrypt-prod \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
    if [[ "$ready" == "True" ]]; then
      row ok "ClusterIssuer" "letsencrypt-prod Ready"
    else
      row fail "ClusterIssuer" "letsencrypt-prod missing or not Ready"
    fi
  else
    row fail "cert-manager" "ClusterIssuer CRD missing"
  fi

  check_hostname_dns
}

check_aws_mode() {
  heading "AWS ALB Mode"

  loading "AWS LB Controller"
  if kubectl get ingressclass alb >/dev/null 2>&1 \
    || kubectl -n kube-system get deploy aws-load-balancer-controller >/dev/null 2>&1; then
    row ok "AWS LB Controller" "detected"
  else
    row fail "AWS LB Controller" "controller not detected"
  fi

  check_hostname_dns

  check_acm_cert
}

check_gateway_mode() {
  heading "Gateway Mode"

  loading "Gateway API CRDs"
  if crd_exists httproutes.gateway.networking.k8s.io && crd_exists gateways.gateway.networking.k8s.io; then
    row ok "Gateway API CRDs" "HTTPRoute and Gateway CRDs present"
    ENVOY_GATEWAY_CLASSES=$(envoy_gateway_classes)
  else
    row fail "Gateway API CRDs" "HTTPRoute and Gateway CRDs are required"
  fi

  local ns="$GATEWAY_NAMESPACE" name="$GATEWAY_NAME" detected=""
  if [[ -z "$ns" || -z "$name" ]]; then
    loading "Gateway discovery"
    detected=$(first_envoy_gateway "$ENVOY_GATEWAY_CLASSES")
    [[ -z "$detected" ]] && detected=$(first_gateway)
    if [[ -n "$detected" ]]; then
      ns=$(awk '{print $1}' <<< "$detected")
      name=$(awk '{print $2}' <<< "$detected")
      GATEWAY_NAMESPACE="$ns"
      GATEWAY_NAME="$name"
    fi
  fi

  if [[ -z "$ns" || -z "$name" ]]; then
    row fail "Gateway resource" "no Gateway specified or detected"
  else
    loading "Gateway resource"
  fi

  if [[ -n "$ns" && -n "$name" ]] && kubectl -n "$ns" get gateway "$name" >/dev/null 2>&1; then
    row ok "Gateway resource" "$ns/$name exists"
    if [[ -n "$GATEWAY_SECTION" ]]; then
      loading "Gateway listener"
      if kubectl -n "$ns" get gateway "$name" \
        -o jsonpath='{range .spec.listeners[*]}{.name}{"\n"}{end}' 2>/dev/null | grep -Fxq "$GATEWAY_SECTION"; then
        row ok "Gateway listener" "$GATEWAY_SECTION exists"
      else
        row fail "Gateway listener" "$GATEWAY_SECTION not found on $ns/$name"
      fi
    else
      local https
      loading "HTTPS listener"
      https=$(gateway_https_section "$ns" "$name")
      if [[ -n "$https" ]]; then
        row ok "HTTPS listener" "$https"
      else
        row warn "HTTPS listener" "no HTTPS listener detected on $ns/$name"
      fi
    fi
  elif [[ -n "$ns" && -n "$name" ]]; then
    row fail "Gateway resource" "$ns/$name not found"
  fi

  if [[ -n "$HOST" || -n "$VALUES_FILE" ]]; then
    check_hostname_dns
  else
    row warn "hostname DNS" "no --host supplied; HTTPRoute hostnames may be empty"
  fi
}

check_mode_requirements() {
  if (( ! CLUSTER_OK )); then
    heading "Mode Requirements"
    row fail "mode checks" "cluster is not reachable"
    return 0
  fi

  case "$MODE" in
    nginx) check_nginx_mode ;;
    aws) check_aws_mode ;;
    gateway) check_gateway_mode ;;
    *) row fail "mode" "not selected" ;;
  esac
}

# ---------------------------------------------------------------------------
# Values Output
# ---------------------------------------------------------------------------
print_values_yaml() {
  heading "Generated values.yaml"
  printf "  ${DIM}Configuration matching the selected ingress mode.${RESET}\n\n"
  printf 'ingress:\n'
  printf '  enabled: true\n'
  printf '  mode: %s\n' "$(yaml_scalar "$MODE")"
  if [[ -n "$HOST" ]]; then
    printf '  host: %s\n' "$(yaml_scalar "$HOST")"
  fi
  case "$MODE" in
    nginx)
      printf '  nginx:\n'
      printf '    tls:\n'
      printf '      enabled: true\n'
      printf '    clusterIssuer: %s\n' "$(yaml_scalar "letsencrypt-prod")"
      printf '    sslRedirect: true\n'
      ;;
    aws)
      printf '  aws:\n'
      printf '    scheme: %s\n' "$(yaml_scalar "internet-facing")"
      if [[ -n "$AWS_CERT_ARN" ]]; then
        printf '    certificateArn: %s\n' "$(yaml_scalar "$AWS_CERT_ARN")"
        printf '    sslRedirect: true\n'
      fi
      ;;
    gateway)
      printf '  gateway:\n'
      [[ -n "$GATEWAY_NAME" ]] && printf '    name: %s\n' "$(yaml_scalar "$GATEWAY_NAME")"
      [[ -n "$GATEWAY_NAMESPACE" ]] && printf '    namespace: %s\n' "$(yaml_scalar "$GATEWAY_NAMESPACE")"
      if [[ -n "$GATEWAY_SECTION" ]]; then
        printf '    sectionName: %s\n' "$(yaml_scalar "$GATEWAY_SECTION")"
      fi
      ;;
  esac

  printf '\ncontrol:\n'
  printf '  rbac:\n'
  printf '    writeNamespaces:\n'
  printf '      - %s\n' "$(yaml_scalar "$NAMESPACE")"
  if [[ -n "$AWS_ROLE_ARN" || -n "$AWS_REGION" ]]; then
    printf '  aws:\n'
    [[ -n "$AWS_ROLE_ARN" ]] && printf '    roleArn: %s\n' "$(yaml_scalar "$AWS_ROLE_ARN")"
    [[ -n "$AWS_REGION" ]] && printf '    region: %s\n' "$(yaml_scalar "$AWS_REGION")"
  fi
}

auth_reminder() {
  [[ -n "$HOST" ]] || return 0
  printf "\n"
  input_error "Configure GitHub or Google auth before exposing the control plane."
  info "For GitHub, create an OAuth App with:"
  printf "\n"
  printf "    ${BOLD}Homepage URL:${RESET}               https://%s\n" "$HOST"
  printf "    ${BOLD}Authorization callback URL:${RESET} https://%s/github/oauth/callback\n" "$HOST"
  printf "\n"
  info "Use the YAML snippet below to configure GitHub auth once you have the Client ID and Secret."
  printf "\n"
  printf "control:\n"
  printf "  config:\n"
  printf "    auth:\n"
  printf "      redirect_base_url: https://%s\n" "$HOST"
  printf "      github:\n"
  printf "        client_id: GITHUB_CLIENT_ID\n"
  printf "        client_secret: GITHUB_CLIENT_SECRET\n"
}

# ---------------------------------------------------------------------------
# Summary / Main
# ---------------------------------------------------------------------------
summary() {
  heading "Summary"
  if (( FAILURES == 0 )); then
    row ok "result" "no blocking prerequisite failures detected"
  else
    printf "  ${RED}${CROSS}${RESET} Found %d blocking prerequisite issue(s).\n" "$FAILURES"
  fi
  if (( WARNINGS > 0 )); then
    printf "  ${YELLOW}${WARN_SYM}${RESET} Found %d warning(s).\n" "$WARNINGS"
  fi
}

run_selected_check() {
  case "$CHECK_TARGET" in
    local)
      check_local_deps
      ;;
    cluster)
      check_local_deps
      check_cluster_access
      ;;
    nginx)
      MODE="nginx"
      check_local_deps
      check_cluster_access
      if (( CLUSTER_AUTH_OK == 0 || CLUSTER_OK == 0 )); then return 0; fi
      check_nginx_mode
      ;;
    aws)
      MODE="aws"
      check_local_deps
      check_cluster_access
      if (( CLUSTER_AUTH_OK == 0 || CLUSTER_OK == 0 )); then return 0; fi
      check_aws_mode
      ;;
    gateway)
      MODE="gateway"
      check_local_deps
      check_cluster_access
      if (( CLUSTER_AUTH_OK == 0 || CLUSTER_OK == 0 )); then return 0; fi
      check_gateway_mode
      ;;
    iam)
      check_iam_local_deps
      if (( FAILURES == 0 )); then
        check_iam_diagnostics
      fi
      ;;
    values)
      choose_mode
      if (( FAILURES == 0 )) && [[ -n "$MODE" ]]; then
        print_values_yaml
        auth_reminder
      fi
      ;;
  esac
}

main() {
  parse_args "$@"
  printf "${BOLD}PgDog EE Control Plane prerequisite checker${RESET}\n"
  if [[ "$CHECK_TARGET" != "all" ]]; then
    run_selected_check
    summary
    return $(( FAILURES == 0 ? 0 : 1 ))
  fi

  check_local_deps
  choose_mode
  check_cluster_access
  if (( CLUSTER_AUTH_OK == 0 )); then
    summary
    return 1
  fi
  check_mode_requirements
  if (( FAILURES == 0 )); then
    check_iam_diagnostics
  fi
  summary
  if (( FAILURES == 0 )) && [[ -n "$MODE" ]]; then
    print_values_yaml
    auth_reminder
  fi
  printf "\n"
  (( FAILURES == 0 ))
}

main "$@"
