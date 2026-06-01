#!/usr/bin/env bash
#
# install.sh — interactive installer for the PgDog EE Control Plane.
#
# This script inspects the target environment, shows the commands it is about
# to run, then asks you to type "confirm" before each mutating action unless
# --yes is passed:
#   1. verify local CLI tools
#   2. scan the cluster for ingress controllers, propose an ingress mode,
#      then check the remaining per-mode deps
#   3. install any missing prerequisites you confirm
#      (ingress-nginx, cert-manager, a Let's Encrypt ClusterIssuer)
#   4. optionally check EKS OIDC / IAM provider readiness and create the IAM
#      role for RDS / CloudWatch access
#   5. run the `helm` commands to install the chart
#   6. list Route53 hosted zones and create the DNS record pointing the
#      hostname at the load balancer when the target is known
#
# Every mutating action is shown before execution. Interactive runs require an
# exact "confirm" response; --yes runs the generated commands automatically.
#
set -euo pipefail

# ──────────────────────────── configuration ────────────────────────────
REPO_NAME="pgdogdev-ee"
REPO_URL="https://helm-ee.pgdog.dev"
CHART="pgdogdev-ee/pgdog-control"

RELEASE="pgdog-control"
NAMESPACE="default"
NAMESPACE_FROM_FLAG=0
MODE=""               # nginx | aws  (chosen interactively when unset)
MODE_FROM_FLAG=0
HOST=""
DNS_PROVIDER=""       # route53 | manual
VALUES_FILE=""
ACME_EMAIL=""
ASSUME_YES=0
AWS_REGION=""
AWS_CLUSTER=""
AWS_ROLE_NAME=""
AWS_ROLE_NAME_FROM_FLAG=0
AWS_ROLE_ARN=""
AWS_CERT_ARN=""
AWS_ALB_SUBNETS=""
CONFIGURE_AWS=0

# state filled in by the checks
MISSING_NGINX=0; MISSING_CERTMGR=0; MISSING_ISSUER=0
HAVE_NGINX=0; HAVE_ALB=0; HAVE_GATEWAY=0
CLUSTER_OK=1
REQUIRED_MISSING=0
ZONE_ID=""; ZONE_NAME=""
GH_CLIENT_ID=""; GH_CLIENT_SECRET=""; GH_ALLOWED_ORGS=""
GATEWAY_NAME=""; GATEWAY_NAMESPACE=""; GATEWAY_SECTION=""
AWS_ACCOUNT_ID=""; OIDC_HOST=""; IAM_OIDC_PROVIDER_EXISTS=0
STEP=0
LOADING_ACTIVE=0

# ───────────────────────────── colors / ui ─────────────────────────────
if [[ -t 1 ]] && command -v tput >/dev/null 2>&1 && [[ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]]; then
  BOLD=$(tput bold); RESET=$(tput sgr0); DIM=$(tput dim)
  RED=$(tput setaf 1); GREEN=$(tput setaf 2); YELLOW=$(tput setaf 3)
  BLUE=$(tput setaf 4); CYAN=$(tput setaf 6)
else
  BOLD=""; RESET=""; DIM=""; RED=""; GREEN=""; YELLOW=""; BLUE=""; CYAN=""
fi
CHECK="✔"; CROSS="✘"; WARN_SYM="⚠"; INFO_SYM="ℹ"

boxed_line() {
  local text=$1 subtext=${2:-} width=49
  if (( ${#text} > width - 6 )); then
    width=$((${#text} + 6))
  fi
  if [[ -n "$subtext" ]] && (( ${#subtext} > width - 6 )); then
    width=$((${#subtext} + 6))
  fi
  local bar
  bar=$(printf '─%.0s' $(seq 1 "$width"))
  printf "\n${CYAN}${BOLD}╭%s╮${RESET}\n" "$bar"
  boxed_line_row "$text" "$width" "$BOLD"
  if [[ -n "$subtext" ]]; then
    boxed_line_row "$subtext" "$width" "$DIM"
  fi
  printf   "${CYAN}${BOLD}╰%s╯${RESET}\n" "$bar"
}

boxed_line_row() {
  local text=$1 width=$2 style=$3 left right
  left=$(((width - ${#text}) / 2))
  right=$((width - ${#text} - left))
  printf "${CYAN}${BOLD}│${RESET}%*s%s%s${RESET}%*s${CYAN}${BOLD}│${RESET}\n" "$left" "" "$style" "$text" "$right" ""
}

banner() {
  boxed_line "PgDog EE · Control Plane Installer"
}

step() { printf "\n${BLUE}${BOLD}%s${RESET}  ${BOLD}%s${RESET}\n" "$1" "$2"; }
# heading <title> — a numbered step; counter advances so the order can vary by mode.
heading() { STEP=$((STEP + 1)); step "Step $STEP" "$1"; }
clear_loading() {
  if (( LOADING_ACTIVE )) && [[ -t 1 ]]; then
    printf "\r\033[K"
  fi
  LOADING_ACTIVE=0
}
loading() {
  if [[ -t 1 ]]; then
    printf "  ${BLUE}…${RESET} %-22s ${DIM}checking...${RESET}\r" "$1"
    LOADING_ACTIVE=1
  else
    printf "  ${BLUE}${INFO_SYM}${RESET} %-22s ${DIM}checking...${RESET}\n" "$1"
  fi
}
info() { clear_loading; printf "  ${BLUE}${INFO_SYM}${RESET} %s\n" "$1"; }
ok()   { clear_loading; printf "  ${GREEN}${CHECK}${RESET} %s\n" "$1"; }
warn() { clear_loading; printf "  ${YELLOW}${WARN_SYM}${RESET} %s\n" "$1"; }
die()  { clear_loading; printf "\n${RED}${BOLD}Aborting:${RESET} %s\n" "$1" >&2; exit 1; }

# snippet <multi-line-string> — render a copy-paste command/manifest block
snippet() {
  printf "\n"
  while IFS= read -r _l; do
    printf "${BOLD}%s${RESET}\n" "$_l"
  done <<< "$1"
  printf "\n"
}

confirm_command() {
  local label=$1 cmd=$2 r
  snippet "$cmd"
  if (( ASSUME_YES )); then
    ok "Auto-confirmed: $label"
  else
    while true; do
      printf "  ${YELLOW}?${RESET} Type ${BOLD}confirm${RESET} to run %s: " "$label"
      read -r r
      [[ "$r" == "confirm" ]] && break
      warn "Type confirm to continue."
    done
  fi
}

confirm_and_run() {
  local label=$1 cmd=$2
  confirm_command "$label" "$cmd"
  info "Running: $label"
  bash -euo pipefail -c "$cmd"
  ok "Completed: $label"
}

# row <ok|bad|warn> <name> <detail>
row() {
  clear_loading
  local color sym
  case "$1" in
    ok)   color=$GREEN;  sym=$CHECK ;;
    bad)  color=$RED;    sym=$CROSS ;;
    warn) color=$YELLOW; sym=$WARN_SYM ;;
  esac
  printf "  ${color}${sym}${RESET} %-22s ${DIM}%s${RESET}\n" "$2" "${3:-}"
}

# have <cmd> — true if the command is available. For testing, list space-
# separated tool names in $FAKE_MISSING to force them to report as missing.
have() {
  case " ${FAKE_MISSING:-} " in *" $1 "*) return 1 ;; esac
  command -v "$1" >/dev/null 2>&1
}
crd_exists() { kubectl get crd "$1" >/dev/null 2>&1; }

ask_yn() { # ask_yn "prompt" -> 0 yes / 1 no
  local r
  while true; do
    printf "  ${YELLOW}?${RESET} %s ${DIM}[y/N]${RESET} " "$1"
    read -r r
    case "$r" in
      [Yy]) return 0 ;;
      [Nn]|"") return 1 ;;
      *) warn "Enter y or n." ;;
    esac
  done
}

confirm_done() {
  local label=$1 r
  if (( ASSUME_YES )); then
    ok "Auto-confirmed: $label"
    return 0
  fi
  while true; do
    printf "  ${YELLOW}?${RESET} Type ${BOLD}confirm${RESET} once %s: " "$label"
    read -r r
    [[ "$r" == "confirm" ]] && return 0
    warn "Type confirm to continue."
  done
}

valid_namespace() {
  [[ ${#1} -le 63 && "$1" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]]
}

valid_nonempty() {
  [[ -n "$1" ]]
}

valid_aws_region() {
  [[ "$1" =~ ^[a-z]{2}(-gov)?-[a-z]+-[0-9]+$ ]]
}

valid_iam_role_name() {
  [[ ${#1} -le 64 && "$1" =~ ^[A-Za-z0-9+=,.@_-]+$ ]]
}

default_aws_role_name() {
  local cluster="${AWS_CLUSTER:-cluster}"
  printf 'pgdog-%s-%s' "$NAMESPACE" "$cluster"
}

valid_ingress_choice() {
  case "$1" in 1|2|3|nginx|aws|gateway) return 0 ;; *) return 1 ;; esac
}

valid_controller_choice() {
  case "$1" in 1|2|3|nginx|aws|both) return 0 ;; *) return 1 ;; esac
}

valid_dns_provider_choice() {
  case "$1" in 1|2|route53|manual) return 0 ;; *) return 1 ;; esac
}

valid_acm_domain() {
  [[ ${#1} -le 253 && "$1" =~ ^(\*\.)?([A-Za-z0-9]([-A-Za-z0-9]{0,61}[A-Za-z0-9])?\.)+[A-Za-z0-9]([-A-Za-z0-9]{0,61}[A-Za-z0-9])?$ ]]
}

valid_host_in_zone() {
  valid_acm_domain "$1" || return 1
  local host="${1%.}" zone="${ZONE_NAME%.}"
  [[ -n "$zone" && "$host" == *".${zone}" && "$host" != "$zone" ]]
}

prompt_until() {
  local prompt=$1 default=${2:-} validator=${3:-} invalid=${4:-"Invalid input."}
  while true; do
    if [[ -n "$default" ]]; then
      printf "  ${YELLOW}?${RESET} %s ${DIM}[%s]${RESET}: " "$prompt" "$default"
    else
      printf "  ${YELLOW}?${RESET} %s: " "$prompt"
    fi
    read -r PROMPT_VALUE
    PROMPT_VALUE="${PROMPT_VALUE:-$default}"
    if [[ -z "$validator" ]] || "$validator" "$PROMPT_VALUE"; then
      return 0
    fi
    warn "$invalid"
  done
}

prompt_select() {
  local prompt=$1 count=$2 default=${3:-1}
  while true; do
    printf "  ${YELLOW}?${RESET} %s ${DIM}[1-%d, default %s]${RESET}: " "$prompt" "$count" "$default"
    read -r PROMPT_VALUE
    PROMPT_VALUE="${PROMPT_VALUE:-$default}"
    if [[ "$PROMPT_VALUE" =~ ^[0-9]+$ ]] && (( PROMPT_VALUE >= 1 && PROMPT_VALUE <= count )); then
      return 0
    fi
    warn "Invalid selection."
  done
}

# Best-effort open a URL in the host browser (no-op if no opener available).
open_url() {
  if   have open;     then open "$1"     >/dev/null 2>&1 || true
  elif have xdg-open; then xdg-open "$1" >/dev/null 2>&1 || true
  fi
}

is_kube_auth_error() {
  [[ "$1" =~ [Ff]orbidden|[Uu]nauthorized|[Pp]ermission[[:space:]]denied|must[[:space:]]be[[:space:]]logged[[:space:]]in|the[[:space:]]server[[:space:]]has[[:space:]]asked[[:space:]]for[[:space:]]the[[:space:]]client[[:space:]]to[[:space:]]provide[[:space:]]credentials|You[[:space:]]must[[:space:]]be[[:space:]]logged[[:space:]]in ]]
}

# ─────────────────────────── ingress mode menu ─────────────────────────
# Proposes an ingress mode based on the controller scan (scan_controllers)
# and lets the user accept the default with Enter or override. Honors --mode.
choose_mode() {
  if (( MODE_FROM_FLAG )); then
    ok "Ingress mode: ${BOLD}${MODE}${RESET} ${DIM}(from --mode)${RESET}"
    return 0
  fi

  local default reason
  if   (( ! CLUSTER_OK )); then default="nginx";   reason="cluster unreachable; chart default"
  elif (( HAVE_NGINX ));   then default="nginx";   reason="ingress-nginx detected"
  elif (( HAVE_ALB ));     then default="aws";     reason="AWS LB Controller detected"
  elif (( HAVE_GATEWAY )); then default="gateway"; reason="Gateway API detected"
  else
    info "No supported ingress path was detected."
    choose_controller_to_install
    info "If your controller uses custom names and you want to override detection, re-run with --mode nginx, --mode aws, or --mode gateway."
    die "No ingress controller detected."
  fi

  info "Proposed ingress mode: ${BOLD}${default}${RESET} ${DIM}(${reason})${RESET}"
  if (( ASSUME_YES )); then MODE="$default"; ok "Ingress mode: ${BOLD}${MODE}${RESET}"; return 0; fi

  local dnum
  case "$default" in aws) dnum=2 ;; gateway) dnum=3 ;; *) dnum=1 ;; esac
  printf "    ${BOLD}1)${RESET} nginx     ${DIM}ingress-nginx + cert-manager (Let's Encrypt TLS)${RESET}\n"
  printf "    ${BOLD}2)${RESET} aws       ${DIM}AWS Load Balancer Controller (ALB + ACM TLS)${RESET}\n"
  printf "    ${BOLD}3)${RESET} gateway   ${DIM}Gateway API HTTPRoute (TLS at the Gateway)${RESET}\n"
  prompt_until "Press enter to accept ${default}, or choose 1/2/3" "$dnum" valid_ingress_choice "Enter 1 (nginx), 2 (aws), or 3 (gateway)."
  case "$PROMPT_VALUE" in
    1|nginx) MODE="nginx" ;;
    2|aws) MODE="aws" ;;
    3|gateway) MODE="gateway" ;;
  esac
  ok "Ingress mode: ${BOLD}${MODE}${RESET}"
}

# ───────────────────────── namespace selection ─────────────────────────
# Asks which namespace the control chart should be installed into. This
# namespace is also used for generated ServiceAccount trust in IRSA.
prompt_namespace() {
  if (( NAMESPACE_FROM_FLAG )); then
    ok "Namespace: ${BOLD}${NAMESPACE}${RESET} ${DIM}(from --namespace)${RESET}"
    return 0
  fi
  if (( ASSUME_YES )); then
    ok "Namespace: ${BOLD}${NAMESPACE}${RESET}"
    return 0
  fi

  step "Namespace" "Kubernetes namespace for the control chart"
  prompt_until "Install namespace" "$NAMESPACE" valid_namespace "Use a valid Kubernetes namespace name: lowercase alphanumerics and '-', up to 63 chars."
  NAMESPACE="$PROMPT_VALUE"
  ok "Namespace: ${BOLD}${NAMESPACE}${RESET}"
}

# ─────────────────────────── gateway details ───────────────────────────
# Gateway mode renders an HTTPRoute that attaches to an existing Gateway.
# Prompt for that Gateway's name/namespace (required) and listener section
# (optional), defaulting to the first Gateway found in the cluster.
prompt_gateway() {
  [[ "$MODE" == "gateway" ]] || return 0
  if (( ASSUME_YES )); then return 0; fi

  step "Gateway" "Gateway the HTTPRoute attaches to"
  local def_ns="" def_name="" line
  if (( CLUSTER_OK )); then
    loading "Gateway"
    line=$(kubectl get gateways.gateway.networking.k8s.io -A --no-headers 2>/dev/null | head -n1 || true)
    clear_loading
    def_ns=$(awk '{print $1}' <<< "$line")
    def_name=$(awk '{print $2}' <<< "$line")
    [[ -n "$def_name" ]] && info "Detected Gateway: ${BOLD}${def_name}${RESET} in ${BOLD}${def_ns}${RESET}"
  fi
  prompt_until "Gateway name" "$def_name" valid_nonempty "Gateway name is required."
  GATEWAY_NAME="$PROMPT_VALUE"
  prompt_until "Gateway namespace" "$def_ns" valid_namespace "Use a valid Kubernetes namespace name: lowercase alphanumerics and '-', up to 63 chars."
  GATEWAY_NAMESPACE="$PROMPT_VALUE"
  prompt_until "Listener sectionName (optional, blank = all)" "" "" ""
  GATEWAY_SECTION="$PROMPT_VALUE"
}

# ───────────────────────────── DNS provider ────────────────────────────
prompt_dns_provider() {
  [[ -n "$DNS_PROVIDER" ]] && return 0
  if ! have aws; then
    DNS_PROVIDER="manual"
    info "DNS mode: ${BOLD}manual${RESET} ${DIM}(AWS CLI not found)${RESET}"
    return 0
  fi
  if (( ASSUME_YES )); then
    DNS_PROVIDER="route53"
    ok "DNS mode: ${BOLD}Route53${RESET}"
    return 0
  fi

  printf "    ${BOLD}1)${RESET} Route53   ${DIM}create the DNS record with AWS Route53${RESET}\n"
  printf "    ${BOLD}2)${RESET} Manual    ${DIM}show the record for you to create yourself${RESET}\n"
  prompt_until "Choose DNS setup" 1 valid_dns_provider_choice "Enter 1 (Route53) or 2 (Manual)."
  case "$PROMPT_VALUE" in
    1|route53) DNS_PROVIDER="route53" ;;
    2|manual) DNS_PROVIDER="manual" ;;
  esac
  ok "DNS mode: ${BOLD}${DNS_PROVIDER}${RESET}"
}

# ───────────────────────── hostname selection ──────────────────────────
# Asks for the external hostname. When the AWS CLI is available it first
# lists the Route53 hosted zones (read-only) so you can pick one and build
# the host from it; the chosen zone is remembered and reused in the DNS step.
prompt_host() {
  if [[ -n "$VALUES_FILE" ]]; then return 0; fi
  if (( ASSUME_YES )); then return 0; fi

  step "Hostname" "External hostname for the dashboard (ingress.host)"
  prompt_dns_provider
  if [[ "$DNS_PROVIDER" == "route53" ]] && choose_hosted_zone; then
    if [[ -n "$HOST" ]] && ! valid_host_in_zone "$HOST"; then
      warn "${HOST} is not a subdomain of ${ZONE_NAME}."
      HOST=""
    fi
    if [[ -n "$HOST" ]]; then
      ok "Hostname: ${BOLD}${HOST}${RESET}"
      return 0
    fi
    prompt_until "Record hostname" "${NAMESPACE}.${ZONE_NAME}" valid_host_in_zone "Enter a subdomain of ${ZONE_NAME}, e.g. ${NAMESPACE}.${ZONE_NAME}."
    HOST="$PROMPT_VALUE"
  else
    [[ "$DNS_PROVIDER" == "manual" ]] && info "Manual DNS mode selected."
    if [[ -z "$HOST" ]]; then
      prompt_until "External hostname, e.g. control.acme.com" "" valid_acm_domain "Enter a valid DNS name, e.g. control.example.com."
      HOST="$PROMPT_VALUE"
    fi
  fi
  if [[ -n "$HOST" ]]; then ok "Hostname: ${BOLD}${HOST}${RESET}"; fi
}

# ─────────────────────── github oauth app setup ────────────────────────
# GitHub has no API to create OAuth Apps, so this guides the manual
# registration: it computes the homepage + callback URLs from the hostname,
# opens the creation page, then captures the Client ID / secret. The values
# are emitted into the install config by advise_install.
setup_github_oauth() {
  heading "GitHub OAuth login  ${DIM}(optional)${RESET}"
  if (( ASSUME_YES )) || [[ -z "$HOST" ]]; then
    info "Skipped — needs an interactive session and a hostname."
    return 0
  fi
  if ! ask_yn "Configure GitHub OAuth login now?"; then
    info "Skipped GitHub OAuth setup."
    return 0
  fi
  have gh || warn "gh CLI not found — continuing with manual steps."

  local base="https://$HOST"
  local callback="$base/github/oauth/callback"

  local org create_url default_org=""
  if have gh; then
    # Detect orgs the authenticated user belongs to; default to the first.
    local orgs; orgs=$(gh api user/orgs --jq '.[].login' 2>/dev/null || true)
    if [[ -n "$orgs" ]]; then
      info "Your GitHub orgs: ${BOLD}$(echo "$orgs" | paste -sd ', ' -)${RESET}"
      default_org=$(echo "$orgs" | head -n1)
    fi
  fi
  prompt_until "GitHub org for the OAuth app" "$default_org" "" ""
  org="$PROMPT_VALUE"
  if [[ -n "$org" ]]; then
    create_url="https://github.com/organizations/${org}/settings/applications/new"
  else
    create_url="https://github.com/settings/applications/new"
  fi

  info "Register a new OAuth App with these values:"
  snippet "Application name:           PgDog Control Plane
Homepage URL:               ${base}
Authorization callback URL: ${callback}"
  info "Creation page:"
  snippet "$create_url"
  if ask_yn "Open this URL in your browser?"; then open_url "$create_url"; fi

  info "After 'Register application', generate a client secret, then paste both:"
  prompt_until "Client ID" "" valid_nonempty "Client ID is required."
  GH_CLIENT_ID="$PROMPT_VALUE"
  prompt_until "Client secret" "" valid_nonempty "Client secret is required."
  GH_CLIENT_SECRET="$PROMPT_VALUE"
  [[ -n "$org" ]] && GH_ALLOWED_ORGS="$org"
  ok "GitHub OAuth captured — config will be shown with the install step."
}

# ───────────────────────────── AWS ACM TLS ─────────────────────────────
setup_aws_acm_tls() {
  [[ "$MODE" == "aws" ]] || return 0
  if [[ -n "$AWS_CERT_ARN" ]]; then
    ok "ACM certificate: ${BOLD}${AWS_CERT_ARN}${RESET}"
    return 0
  fi
  if (( ASSUME_YES )); then
    info "Skipped ACM TLS setup — pass --acm-cert-arn to configure HTTPS non-interactively."
    return 0
  fi
  if [[ -z "$HOST" ]]; then
    warn "Skipped ACM TLS setup — ingress.host is required to find or request a certificate."
    return 0
  fi
  if ! have aws; then
    warn "AWS CLI not found — set ingress.aws.certificateArn manually for HTTPS."
    return 0
  fi

  heading "AWS ALB TLS  ${DIM}(ACM certificate)${RESET}"
  if ! ask_yn "Configure HTTPS for the ALB with an ACM certificate?"; then
    info "Skipped ACM TLS setup — ALB will be HTTP-only unless your values file sets ingress.aws.certificateArn."
    return 0
  fi
  if ! valid_acm_domain "$HOST"; then
    warn "ACM requires a fully qualified domain name, e.g. control.example.com."
    prompt_until "Public DNS name for the ALB/ACM certificate" "" valid_acm_domain "Enter a valid DNS name with a domain suffix, e.g. pgdog-control-test.example.com."
    HOST="$PROMPT_VALUE"
    ok "Hostname: ${BOLD}${HOST}${RESET}"
  fi

  derive_eks_from_context || true
  local region="${AWS_REGION:-AWS_REGION}"
  local detected=""
  if [[ "$region" != "AWS_REGION" ]]; then
    loading "ACM certificate"
    detected=$(aws acm list-certificates \
      --region "$region" \
      --certificate-statuses ISSUED \
      --query "CertificateSummaryList[?DomainName=='${HOST}'].CertificateArn | [0]" \
      --output text 2>/dev/null || true)
    clear_loading
    [[ "$detected" == "None" ]] && detected=""
  fi

  [[ -n "$detected" ]] && info "Detected issued ACM certificate for ${BOLD}${HOST}${RESET}."
  prompt_until "ACM certificate ARN" "$detected" "" ""
  AWS_CERT_ARN="$PROMPT_VALUE"

  if [[ -n "$AWS_CERT_ARN" ]]; then
    ok "ACM certificate: ${BOLD}${AWS_CERT_ARN}${RESET}"
    return 0
  fi

  if [[ -z "$ZONE_ID" ]] && (( ASSUME_YES == 0 )); then
    choose_hosted_zone || true
  fi
  local zone="${ZONE_ID:-HOSTED_ZONE_ID}"

  local request_cmd="aws acm request-certificate \\
--region $region \\
--domain-name $HOST \\
--validation-method DNS \\
--query CertificateArn \\
--output text"
  info "Request a DNS-validated ACM certificate:"
  if [[ "$region" == "AWS_REGION" ]]; then
    warn "ACM certificate request still has placeholders; not running it."
    snippet "$request_cmd"
    die "ACM certificate ARN is required for AWS ALB HTTPS — request/validate a cert, then re-run this installer."
  fi

  confirm_command "ACM certificate request" "$request_cmd"
  info "Running: ACM certificate request"
  AWS_CERT_ARN=$(aws acm request-certificate \
    --region "$region" \
    --domain-name "$HOST" \
    --validation-method DNS \
    --query CertificateArn \
    --output text)
  ok "ACM certificate requested: ${BOLD}${AWS_CERT_ARN}${RESET}"

  loading "ACM DNS validation"
  local rr_name="" rr_type="" rr_value="" attempt
  for attempt in {1..20}; do
    rr_name=$(aws acm describe-certificate \
      --region "$region" \
      --certificate-arn "$AWS_CERT_ARN" \
      --query 'Certificate.DomainValidationOptions[0].ResourceRecord.Name' \
      --output text 2>/dev/null || true)
    rr_type=$(aws acm describe-certificate \
      --region "$region" \
      --certificate-arn "$AWS_CERT_ARN" \
      --query 'Certificate.DomainValidationOptions[0].ResourceRecord.Type' \
      --output text 2>/dev/null || true)
    rr_value=$(aws acm describe-certificate \
      --region "$region" \
      --certificate-arn "$AWS_CERT_ARN" \
      --query 'Certificate.DomainValidationOptions[0].ResourceRecord.Value' \
      --output text 2>/dev/null || true)
    if [[ -n "$rr_name" && "$rr_name" != "None" && -n "$rr_type" && "$rr_type" != "None" && -n "$rr_value" && "$rr_value" != "None" ]]; then
      break
    fi
    sleep 3
  done
  clear_loading
  if [[ -z "$rr_name" || "$rr_name" == "None" || -z "$rr_type" || "$rr_type" == "None" || -z "$rr_value" || "$rr_value" == "None" ]]; then
    die "ACM did not return DNS validation records yet — re-run with --acm-cert-arn $AWS_CERT_ARN after records are available."
  fi
  ok "ACM validation record: ${BOLD}${rr_name}${RESET} ${rr_type} ${rr_value}"

  local validation_cmd="aws route53 change-resource-record-sets \\
--hosted-zone-id $zone \\
--change-batch '{
  \"Comment\": \"ACM DNS validation for $HOST\",
  \"Changes\": [{
    \"Action\": \"UPSERT\",
    \"ResourceRecordSet\": {
      \"Name\": \"$rr_name\",
      \"Type\": \"$rr_type\",
      \"TTL\": 300,
      \"ResourceRecords\": [{ \"Value\": \"$rr_value\" }]
    }
  }]
}'

aws acm wait certificate-validated \\
--region $region \\
--certificate-arn \"$AWS_CERT_ARN\""
  info "Create the ACM DNS validation record and wait for issuance:"
  if [[ "$zone" == "HOSTED_ZONE_ID" ]]; then
    warn "ACM DNS validation command still has placeholders; not running it."
    snippet "$validation_cmd"
    die "ACM certificate DNS validation needs a hosted zone — validate $AWS_CERT_ARN, then re-run with --acm-cert-arn."
  else
    confirm_and_run "ACM DNS validation record creation" "$validation_cmd"
  fi
  ok "ACM certificate: ${BOLD}${AWS_CERT_ARN}${RESET}"
}

detect_aws_alb_subnets() {
  [[ "$MODE" == "aws" ]] || return 0
  [[ -z "$AWS_ALB_SUBNETS" ]] || return 0
  have aws || return 0
  derive_eks_from_context || true
  [[ -n "$AWS_CLUSTER" && -n "$AWS_REGION" ]] || return 0

  loading "ALB subnets"
  AWS_ALB_SUBNETS=$(aws eks describe-cluster \
    --name "$AWS_CLUSTER" \
    --region "$AWS_REGION" \
    --query 'join(`,`, cluster.resourcesVpcConfig.subnetIds)' \
    --output text 2>/dev/null || true)
  clear_loading
  [[ "$AWS_ALB_SUBNETS" == "None" ]] && AWS_ALB_SUBNETS=""
  [[ -n "$AWS_ALB_SUBNETS" ]] && ok "ALB subnets: ${BOLD}${AWS_ALB_SUBNETS}${RESET}"
}

# ──────────────────────────── AWS / IRSA setup ─────────────────────────
# The chart already supports EKS IRSA through control.aws.roleArn. This
# section checks whether the current EKS cluster has an IAM OIDC provider
# registered, then creates the IAM role and attaches the
# read-only RDS / CloudWatch policy the control plane needs.
derive_eks_from_context() {
  local ctx cluster_ref
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
  if ! have aws; then return 1; fi

  loading "EKS OIDC issuer"
  AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null || true)
  OIDC_HOST=$(aws eks describe-cluster --name "$AWS_CLUSTER" --region "$AWS_REGION" \
    --query 'cluster.identity.oidc.issuer' --output text 2>/dev/null | sed 's|^https://||' || true)

  if [[ -z "$AWS_ACCOUNT_ID" || -z "$OIDC_HOST" || "$OIDC_HOST" == "None" ]]; then
    clear_loading
    return 1
  fi

  loading "IAM OIDC provider"
  local provider_arn="arn:aws:iam::${AWS_ACCOUNT_ID}:oidc-provider/${OIDC_HOST}"
  if aws iam get-open-id-connect-provider --open-id-connect-provider-arn "$provider_arn" >/dev/null 2>&1; then
    IAM_OIDC_PROVIDER_EXISTS=1
  fi
  clear_loading
  return 0
}

abort_for_missing_oidc_provider() {
  local cluster="${AWS_CLUSTER:-CLUSTER_NAME}"
  local region="${AWS_REGION:-AWS_REGION}"
  if [[ -n "$OIDC_HOST" ]]; then
    warn "The cluster has an OIDC issuer, but the matching IAM OIDC provider is not registered."
    require_eksctl
    info "Create the IAM OIDC provider, then re-run this installer:"
    snippet "eksctl utils associate-iam-oidc-provider \\
--cluster $cluster \\
--region $region \\
--approve"
  else
    warn "OIDC provider status is unknown; verify the cluster details and register the provider if needed."
    require_eksctl
    snippet "aws eks describe-cluster \\
--name $cluster \\
--region $region \\
--query 'cluster.identity.oidc.issuer' \\
--output text

eksctl utils associate-iam-oidc-provider \\
--cluster $cluster \\
--region $region \\
--approve"
  fi
  die "EKS IAM OIDC provider is required before creating the PgDog IAM role."
}

setup_aws_access() {
  heading "AWS access for RDS  ${DIM}(optional, EKS IRSA)${RESET}"
  if [[ -n "$AWS_ROLE_ARN" ]]; then
    CONFIGURE_AWS=1
    ok "Using IAM role: ${BOLD}${AWS_ROLE_ARN}${RESET}"
    [[ -n "$AWS_REGION" ]] || derive_eks_from_context || true
    [[ -n "$AWS_REGION" ]] && ok "AWS region: ${BOLD}${AWS_REGION}${RESET}"
    if [[ -n "$AWS_CLUSTER" && -n "$AWS_REGION" ]] && discover_eks_oidc; then
      if (( IAM_OIDC_PROVIDER_EXISTS )); then
        row ok "IAM OIDC provider" "registered in account $AWS_ACCOUNT_ID"
      else
        row bad "IAM OIDC provider" "not registered in account $AWS_ACCOUNT_ID"
        abort_for_missing_oidc_provider
      fi
    elif [[ -n "$AWS_CLUSTER" && -n "$AWS_REGION" ]]; then
      abort_for_missing_oidc_provider
    fi
    return 0
  fi

  if (( ASSUME_YES && CONFIGURE_AWS == 0 )); then
    info "Skipped — pass --aws-role-arn for an existing role or --aws-role-name with --aws-cluster/--aws-region to create the IAM role."
    return 0
  fi
  if ! have aws; then
    if (( CONFIGURE_AWS )); then
      warn "AWS CLI is missing — OIDC checks are skipped and IAM commands will use placeholders."
    else
      info "Skipped — AWS CLI is required to inspect EKS OIDC and create the IAM role."
      return 0
    fi
  fi
  if (( CONFIGURE_AWS == 0 )); then
    if ! ask_yn "Configure an IAM role so PgDog can read RDS and CloudWatch?"; then
      info "Skipped AWS access setup."
      return 0
    fi
    CONFIGURE_AWS=1
  fi

  derive_eks_from_context || true
  if (( ASSUME_YES == 0 )); then
    prompt_until "EKS cluster name" "$AWS_CLUSTER" valid_nonempty "EKS cluster name is required."
    AWS_CLUSTER="$PROMPT_VALUE"
    prompt_until "AWS region" "$AWS_REGION" valid_aws_region "Enter a valid AWS region, e.g. us-west-2."
    AWS_REGION="$PROMPT_VALUE"
    if (( AWS_ROLE_NAME_FROM_FLAG == 0 )); then
      AWS_ROLE_NAME="$(default_aws_role_name)"
    fi
    prompt_until "IAM role name" "$AWS_ROLE_NAME" valid_iam_role_name "Use a valid IAM role name: letters, numbers, and +=,.@_- up to 64 chars."
    AWS_ROLE_NAME="$PROMPT_VALUE"
  fi

  if [[ -z "$AWS_CLUSTER" || -z "$AWS_REGION" ]]; then
    warn "Missing cluster or region — IAM commands will use placeholders."
    return 0
  fi
  if [[ -z "$AWS_ROLE_NAME" ]]; then
    AWS_ROLE_NAME="$(default_aws_role_name)"
  fi

  if discover_eks_oidc; then
    row ok "EKS cluster" "$AWS_CLUSTER ($AWS_REGION)"
    row ok "OIDC issuer" "$OIDC_HOST"
    if (( IAM_OIDC_PROVIDER_EXISTS )); then
      row ok "IAM OIDC provider" "registered in account $AWS_ACCOUNT_ID"
    else
      row bad "IAM OIDC provider" "not registered in account $AWS_ACCOUNT_ID"
      abort_for_missing_oidc_provider
    fi
  else
    abort_for_missing_oidc_provider
  fi
}

# ─────────────────────────── step 1: local deps ────────────────────────
# check_local <name> <cmd> <version-args> <required:0|1> <note>
check_local() {
  local name=$1 cmd=$2 vargs=$3 required=$4 note=${5:-}
  if have "$cmd"; then
    local ver=""
    [[ -n "$vargs" ]] && ver=$($cmd $vargs 2>&1 | head -n1 | cut -c1-42 || true)
    row ok "$name" "$ver"
  elif (( required )); then
    row bad "$name" "missing — $note"; REQUIRED_MISSING=1
  else
    row warn "$name" "missing — $note"
  fi
}

check_local_deps() {
  heading "Local dependencies  ${DIM}(your machine)${RESET}"
  check_local "helm"    helm    "version --short"  1 "https://helm.sh/docs/intro/install/"
  check_local "kubectl" kubectl "version --client" 1 "https://kubernetes.io/docs/tasks/tools/"
  check_local "aws"     aws     "--version"        0 "required for aws ingress mode & IRSA / Route53"
  check_local "eksctl"  eksctl  "version"          0 "only needed for OIDC/IRSA setup"
  check_local "gh"      gh      "--version"        0 "required to configure GitHub OAuth login"
  if (( REQUIRED_MISSING )); then
    die "Required tools are missing — install them before continuing."
  fi
}

# ─────────────────────────── step 2: cluster check ─────────────────────
# Scans the cluster for ingress controllers (read-only) so choose_mode can
# propose a sensible default. Sets HAVE_NGINX / HAVE_ALB.
scan_controllers() {
  HAVE_NGINX=0; HAVE_ALB=0
  if (( ! CLUSTER_OK )); then
    row warn "ingress controllers" "cannot scan — cluster unreachable"
    return 0
  fi
  loading "ingress-nginx"
  if kubectl get ingressclass nginx >/dev/null 2>&1 \
     || kubectl -n ingress-nginx get deploy ingress-nginx-controller >/dev/null 2>&1; then
    HAVE_NGINX=1; row ok "ingress-nginx" "controller present"
  else
    row warn "ingress-nginx" "not detected"
  fi
  loading "AWS LB Controller"
  if kubectl get ingressclass alb >/dev/null 2>&1 \
     || kubectl -n kube-system get deploy aws-load-balancer-controller >/dev/null 2>&1; then
    HAVE_ALB=1; row ok "AWS LB Controller" "present"
  else
    row warn "AWS LB Controller" "not detected"
  fi
  # Gateway API: HTTPRoute mode needs the gateway.networking.k8s.io CRDs and
  # at least one Gateway resource for the HTTPRoute to attach to. A controller
  # being installed shows up as a GatewayClass but is not itself a Gateway.
  loading "Gateway API"
  if crd_exists httproutes.gateway.networking.k8s.io \
     && crd_exists gateways.gateway.networking.k8s.io; then
    local classes
    classes=$(kubectl get gatewayclasses.gateway.networking.k8s.io \
                -o jsonpath='{range .items[*]}{.metadata.name} {end}' 2>/dev/null || true)
    if [[ -n "$(kubectl get gateways.gateway.networking.k8s.io -A --no-headers 2>/dev/null)" ]]; then
      HAVE_GATEWAY=1; row ok "Gateway API" "CRDs + Gateway present"
    elif [[ -n "$classes" ]]; then
      row warn "Gateway API" "GatewayClass: ${classes% } — create a Gateway resource"
    else
      # No GatewayClass yet. A controller may still be installed (e.g. Envoy
      # Gateway doesn't ship a GatewayClass — you create one). Don't claim the
      # controller is absent; just point at the missing pieces.
      row warn "Gateway API" "CRDs present — create a GatewayClass + Gateway"
    fi
  else
    row warn "Gateway API" "CRDs not installed"
  fi
}

check_cluster_deps() {
  heading "Cluster check  ${DIM}(current kube context, read-only)${RESET}"
  loading "kube API"
  local cluster_err=""
  if cluster_err=$(kubectl cluster-info 2>&1 >/dev/null); then
    row ok "kube API reachable" "context: $(kubectl config current-context 2>/dev/null || echo '?')"
  else
    if is_kube_auth_error "$cluster_err"; then
      row bad "kube API auth" "permission denied for context: $(kubectl config current-context 2>/dev/null || echo '?')"
      info "kubectl reached the API server, but this identity is not authorized."
      if have aws; then
        local principal
        principal=$(aws sts get-caller-identity --query Arn --output text 2>/dev/null || true)
        derive_eks_from_context || true
        local eks_cluster="${AWS_CLUSTER:-CLUSTER_NAME}"
        local eks_region="${AWS_REGION:-REGION}"
        [[ -n "$principal" ]] && info "Current AWS principal: ${BOLD}${principal}${RESET}"
        info "For EKS, grant this IAM principal cluster access, then re-run:"
        snippet "aws eks list-access-entries \\
--cluster-name $eks_cluster \\
--region $eks_region

aws eks create-access-entry \\
--cluster-name $eks_cluster \\
--region $eks_region \\
--principal-arn ${principal:-<IAM_PRINCIPAL_ARN>}

aws eks associate-access-policy \\
--cluster-name $eks_cluster \\
--region $eks_region \\
--principal-arn ${principal:-<IAM_PRINCIPAL_ARN>} \\
--policy-arn arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy \\
--access-scope type=cluster"
      else
        info "AWS CLI not found — install it or ask a cluster admin to grant this IAM principal EKS access."
      fi
      die "kubectl can reach the cluster, but your identity is not authorized."
    fi

    row bad "kube API reachable" "no reachable cluster"
    if ! have aws; then
      die "kubectl cannot reach a cluster and the AWS CLI is missing — install the AWS CLI (required to configure EKS access), then re-run."
    fi
    info "Configure kube access, then re-run. For EKS, list and select a cluster:"
    snippet "aws eks list-clusters --region <REGION>
aws eks update-kubeconfig --name <CLUSTER> --region <REGION>"
    info "Verify with: kubectl config current-context"
    die "kubectl cannot reach a cluster — configure your kube context and re-run."
  fi

  # Controller scan first, then propose the ingress mode from what we found.
  scan_controllers
  choose_mode

  # Remaining mode-specific checks.
  case "$MODE" in
    nginx)
      MISSING_NGINX=$(( HAVE_NGINX ? 0 : 1 ))
      if (( CLUSTER_OK )); then
        check_certmanager; check_clusterissuer
      else
        MISSING_CERTMGR=1; MISSING_ISSUER=1
      fi
      if (( MISSING_NGINX || MISSING_CERTMGR || MISSING_ISSUER )); then
        advise_prereqs
        die "nginx prerequisites were missing — finish any pending setup, then re-run this installer."
      fi
      ;;
    aws)
      if ! have aws; then warn "AWS CLI is required for aws mode — install it (see step 1)."; fi
      if (( ! HAVE_ALB )); then
        info "Install the AWS Load Balancer Controller before deploying in aws mode:"
        info "  https://kubernetes-sigs.github.io/aws-load-balancer-controller/"
      fi
      ;;
    gateway)
      if (( ! HAVE_GATEWAY )); then
        info "Gateway API not fully ready — install the gateway.networking.k8s.io CRDs"
        info "and create a Gateway resource before the HTTPRoute can attach."
      fi
      ;;
  esac
}

check_certmanager() {
  loading "cert-manager"
  if crd_exists clusterissuers.cert-manager.io; then
    row ok "cert-manager" "CRDs present"
  else
    row bad "cert-manager" "not installed"; MISSING_CERTMGR=1
  fi
}

check_clusterissuer() {
  if (( MISSING_CERTMGR )); then
    row warn "ClusterIssuer" "skipped (cert-manager absent)"; MISSING_ISSUER=1; return
  fi
  local ready
  loading "ClusterIssuer"
  ready=$(kubectl get clusterissuer letsencrypt-prod \
            -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
  if [[ "$ready" == "True" ]]; then
    row ok "ClusterIssuer" "letsencrypt-prod Ready"
  else
    row bad "ClusterIssuer" "letsencrypt-prod not Ready"; MISSING_ISSUER=1
  fi
}

# ──────────────────── step 3: prerequisite advice ──────────────────────
advise_ingress_nginx() {
  info "Install ingress-nginx:"
  derive_eks_from_context || true
  local cluster="${AWS_CLUSTER:-CLUSTER_NAME}"
  local region="${AWS_REGION:-AWS_REGION}"
  if [[ "$cluster" == "CLUSTER_NAME" || "$region" == "AWS_REGION" ]]; then
    warn "Cluster or region is unknown, so the ingress-nginx install command still has placeholders."
    snippet "CLUSTER=$cluster
REGION=$region
SUBNETS=\$(aws eks describe-cluster \\
--name \"\$CLUSTER\" \\
--region \"\$REGION\" \\
--query 'join(\`,\`, cluster.resourcesVpcConfig.subnetIds)' \\
--output text)

helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update
helm install ingress-nginx ingress-nginx/ingress-nginx \\
--namespace ingress-nginx --create-namespace \\
--set controller.service.type=LoadBalancer \\
--set-json 'controller.service.annotations={\"service.beta.kubernetes.io/aws-load-balancer-scheme\":\"internet-facing\",\"service.beta.kubernetes.io/aws-load-balancer-subnets\":\"'\"\$SUBNETS\"'\"}'
kubectl -n ingress-nginx get svc ingress-nginx-controller -w   # note the external address"
    return 0
  fi
  local subnets=""
  if have aws; then
    loading "EKS subnets"
    subnets=$(aws eks describe-cluster \
      --name "$cluster" \
      --region "$region" \
      --query 'join(`,`, cluster.resourcesVpcConfig.subnetIds)' \
      --output text 2>/dev/null || true)
    clear_loading
    [[ "$subnets" == "None" ]] && subnets=""
  fi
  if [[ -z "$subnets" ]]; then
    warn "Could not resolve EKS subnets, so the ingress-nginx install command still has placeholders."
    snippet "helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \\
--namespace ingress-nginx --create-namespace \\
--set controller.service.type=LoadBalancer \\
--set-json 'controller.service.annotations={\"service.beta.kubernetes.io/aws-load-balancer-scheme\":\"internet-facing\",\"service.beta.kubernetes.io/aws-load-balancer-subnets\":\"<SUBNET_IDS>\"}'"
    return 0
  fi
  ok "EKS subnets: ${BOLD}${subnets}${RESET}"
  confirm_and_run "ingress-nginx installation" "helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \\
--namespace ingress-nginx --create-namespace \\
--set controller.service.type=LoadBalancer \\
--set-json 'controller.service.annotations={\"service.beta.kubernetes.io/aws-load-balancer-scheme\":\"internet-facing\",\"service.beta.kubernetes.io/aws-load-balancer-subnets\":\"$subnets\"}'"
  info "Watch for the external address with:"
  snippet "kubectl -n ingress-nginx get svc ingress-nginx-controller -w"
}

advise_eksctl_install() {
  warn "eksctl is required for the OIDC / IAM ServiceAccount commands below."
  local os arch
  os=$(uname -s)
  arch=$(uname -m)
  case "$os" in
    Darwin)
      info "Install eksctl on macOS:"
      snippet "brew tap weaveworks/tap
brew install weaveworks/tap/eksctl
eksctl version"
      ;;
    Linux)
      case "$arch" in
        x86_64) arch=amd64 ;;
        aarch64|arm64) arch=arm64 ;;
        *)
          warn "Unsupported Linux architecture: $arch"
          info "See https://eksctl.io/installation/ for manual install options."
          return 0
          ;;
      esac
      info "Install eksctl on Linux:"
      snippet "curl -fsSLo eksctl.tar.gz \"https://github.com/eksctl-io/eksctl/releases/latest/download/eksctl_Linux_${arch}.tar.gz\"
tar -xzf eksctl.tar.gz
sudo install -m 0755 eksctl /usr/local/bin/eksctl
eksctl version"
      ;;
    *)
      warn "Unsupported OS: $os"
      info "See https://eksctl.io/installation/ for manual install options."
      ;;
  esac
}

require_eksctl() {
  have eksctl && return 0
  advise_eksctl_install
  die "eksctl is required — install it, then re-run this installer."
}

advise_aws_load_balancer_controller() {
  info "Install the AWS Load Balancer Controller:"
  require_eksctl
  derive_eks_from_context || true
  local cluster="${AWS_CLUSTER:-CLUSTER_NAME}"
  local region="${AWS_REGION:-AWS_REGION}"
  local account_id="${AWS_ACCOUNT_ID:-}"
  local vpc_id=""
  if have aws; then
    [[ -n "$account_id" ]] || account_id=$(aws sts get-caller-identity --query Account --output text 2>/dev/null || true)
    if [[ "$cluster" != "CLUSTER_NAME" && "$region" != "AWS_REGION" ]]; then
      vpc_id=$(aws eks describe-cluster --name "$cluster" --region "$region" \
        --query 'cluster.resourcesVpcConfig.vpcId' --output text 2>/dev/null || true)
      [[ "$vpc_id" == "None" ]] && vpc_id=""
    fi
  fi
  account_id="${account_id:-ACCOUNT_ID}"
  vpc_id="${vpc_id:-VPC_ID}"
  local policy_exists=0
  if [[ "$account_id" != "ACCOUNT_ID" ]] && have aws; then
    if aws iam get-policy --policy-arn "arn:aws:iam::${account_id}:policy/AWSLoadBalancerControllerIAMPolicy" >/dev/null 2>&1; then
      policy_exists=1
      ok "AWSLoadBalancerControllerIAMPolicy already exists."
    fi
  fi
  local oidc_cmd=""
  if discover_eks_oidc; then
    if (( IAM_OIDC_PROVIDER_EXISTS )); then
      ok "IAM OIDC provider is already registered."
    else
      oidc_cmd="eksctl utils associate-iam-oidc-provider \\
--cluster \"$cluster\" \\
--region \"$region\" \\
--approve

"
    fi
  else
    warn "Could not verify IAM OIDC provider status — check it before creating the IAM ServiceAccount."
  fi
  local policy_cmd=""
  if (( policy_exists == 0 )); then
    policy_cmd="curl -fsSLo aws-load-balancer-controller-policy.json \\
https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/main/docs/install/iam_policy.json

aws iam create-policy \\
--policy-name AWSLoadBalancerControllerIAMPolicy \\
--policy-document file://aws-load-balancer-controller-policy.json

"
  fi
  local controller_cmd="${oidc_cmd}${policy_cmd}eksctl create iamserviceaccount \\
--cluster \"$cluster\" \\
--region \"$region\" \\
--namespace kube-system \\
--name aws-load-balancer-controller \\
--attach-policy-arn \"arn:aws:iam::${account_id}:policy/AWSLoadBalancerControllerIAMPolicy\" \\
--override-existing-serviceaccounts \\
--approve

helm repo add eks https://aws.github.io/eks-charts
helm repo update
helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \\
--namespace kube-system \\
--set clusterName=\"$cluster\" \\
--set region=\"$region\" \\
--set vpcId=\"$vpc_id\" \\
--set serviceAccount.create=false \\
--set serviceAccount.name=aws-load-balancer-controller

kubectl -n kube-system rollout status deployment/aws-load-balancer-controller"
  if [[ "$cluster" == "CLUSTER_NAME" || "$region" == "AWS_REGION" || "$account_id" == "ACCOUNT_ID" || "$vpc_id" == "VPC_ID" ]]; then
    warn "AWS Load Balancer Controller command still has placeholders; not running it."
    snippet "$controller_cmd"
    return 0
  fi
  confirm_and_run "AWS Load Balancer Controller installation" "$controller_cmd"
}

choose_controller_to_install() {
  heading "Ingress controller setup"
  if (( ASSUME_YES )); then
    info "Non-interactive mode: preparing both controller install options."
    advise_ingress_nginx
    advise_aws_load_balancer_controller
    return 0
  fi

  info "Choose the controller you want to install, then re-run this installer after it is ready."
  printf "    ${BOLD}1)${RESET} nginx     ${DIM}ingress-nginx LoadBalancer; use nginx mode${RESET}\n"
  printf "    ${BOLD}2)${RESET} aws       ${DIM}AWS Load Balancer Controller; use aws mode${RESET}\n"
  printf "    ${BOLD}3)${RESET} both      ${DIM}prepare both install options${RESET}\n"

  prompt_until "Choose controller install instructions" 1 valid_controller_choice "Enter 1 (nginx), 2 (aws), or 3 (both)."
  case "$PROMPT_VALUE" in
    1|nginx)
      advise_ingress_nginx
      ;;
    2|aws)
      advise_aws_load_balancer_controller
      ;;
    3|both)
      advise_ingress_nginx
      advise_aws_load_balancer_controller
      ;;
  esac
}

advise_cert_manager() {
  info "Install cert-manager:"
  confirm_and_run "cert-manager installation" "helm repo add jetstack https://charts.jetstack.io
helm repo update
helm upgrade --install cert-manager jetstack/cert-manager \\
--namespace cert-manager --create-namespace \\
--set crds.enabled=true"
}

advise_clusterissuer() {
  local email="${ACME_EMAIL:-your-email@example.com}"
  if [[ -z "$ACME_EMAIL" ]]; then
    warn "No ACME email was provided; pass --email before creating the ClusterIssuer."
    info "ClusterIssuer command:"
    snippet "kubectl apply -f - <<'EOF'
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: ${email}
    privateKeySecretRef:
      name: letsencrypt-prod-account-key
    solvers:
      - http01:
          ingress:
            ingressClassName: nginx
EOF"
    return 0
  fi
  info "Create a Let's Encrypt ClusterIssuer:"
  confirm_and_run "Let's Encrypt ClusterIssuer creation" "kubectl apply -f - <<'EOF'
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: ${email}
    privateKeySecretRef:
      name: letsencrypt-prod-account-key
    solvers:
      - http01:
          ingress:
            ingressClassName: nginx
EOF"
}

advise_prereqs() {
  [[ "$MODE" == "nginx" ]] || return 0
  heading "Cluster prerequisites"
  if (( MISSING_NGINX == 0 && MISSING_CERTMGR == 0 && MISSING_ISSUER == 0 )); then
    ok "All nginx prerequisites are present — nothing to install."
    return 0
  fi
  (( CLUSTER_OK )) || info "Cluster not reachable — showing all prerequisites; skip any already installed."
  info "Install the missing prerequisites in this order:"
  if (( MISSING_NGINX ));   then advise_ingress_nginx; fi
  if (( MISSING_CERTMGR )); then advise_cert_manager; fi
  if (( MISSING_ISSUER ));  then advise_clusterissuer; fi
}

advise_aws_iam_role() {
  (( CONFIGURE_AWS )) || return 0
  [[ -z "$AWS_ROLE_ARN" ]] || return 0

  heading "IAM role for RDS access"

  local cluster="${AWS_CLUSTER:-CLUSTER_NAME}"
  local region="${AWS_REGION:-AWS_REGION}"
  local role="${AWS_ROLE_NAME:-$(default_aws_role_name)}"
  if [[ -z "$AWS_ACCOUNT_ID" ]] && have aws; then
    AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null || true)
  fi
  if [[ -z "$OIDC_HOST" ]] && have aws && [[ "$cluster" != "CLUSTER_NAME" && "$region" != "AWS_REGION" ]]; then
    OIDC_HOST=$(aws eks describe-cluster --name "$cluster" --region "$region" \
      --query 'cluster.identity.oidc.issuer' --output text 2>/dev/null | sed 's|^https://||' || true)
    [[ "$OIDC_HOST" == "None" ]] && OIDC_HOST=""
  fi
  local account="${AWS_ACCOUNT_ID:-ACCOUNT_ID}"
  local oidc="${OIDC_HOST:-OIDC_HOST}"
  local sa="${RELEASE}-control"
  [[ -n "$VALUES_FILE" ]] && warn "If $VALUES_FILE overrides control.rbac.serviceAccountName, change SA below to match it."

  ok "IAM OIDC provider is present — IRSA can be configured for this cluster."

  local iam_cmd="cat > trust-policy.json <<'EOF'
{
  \"Version\": \"2012-10-17\",
  \"Statement\": [
    {
      \"Effect\": \"Allow\",
      \"Principal\": {
        \"Federated\": \"arn:aws:iam::${account}:oidc-provider/${oidc}\"
      },
      \"Action\": \"sts:AssumeRoleWithWebIdentity\",
      \"Condition\": {
        \"StringEquals\": {
          \"${oidc}:sub\": \"system:serviceaccount:${NAMESPACE}:${sa}\",
          \"${oidc}:aud\": \"sts.amazonaws.com\"
        }
      }
    }
  ]
}
EOF

cat > pgdog-control-aws-policy.json <<'EOF'
{
  \"Version\": \"2012-10-17\",
  \"Statement\": [
    {
      \"Sid\": \"RdsTopology\",
      \"Effect\": \"Allow\",
      \"Action\": [
        \"rds:DescribeDBClusters\",
        \"rds:DescribeDBInstances\",
        \"rds:DescribeDBClusterParameters\",
        \"rds:DescribeDBParameters\"
      ],
      \"Resource\": \"*\"
    },
    {
      \"Sid\": \"CloudWatchMetrics\",
      \"Effect\": \"Allow\",
      \"Action\": [
        \"cloudwatch:GetMetricData\"
      ],
      \"Resource\": \"*\"
    },
    {
      \"Sid\": \"Ec2InstanceTypeSpecs\",
      \"Effect\": \"Allow\",
      \"Action\": [
        \"ec2:DescribeInstanceTypes\"
      ],
      \"Resource\": \"*\"
    }
  ]
}
EOF

aws iam create-role \\
--role-name \"$role\" \\
--assume-role-policy-document file://trust-policy.json

aws iam put-role-policy \\
--role-name \"$role\" \\
--policy-name PgDogControlReadRdsAndCloudWatch \\
--policy-document file://pgdog-control-aws-policy.json"
  if [[ "$account" == "ACCOUNT_ID" || "$oidc" == "OIDC_HOST" ]]; then
    warn "IAM role command still has placeholders; not running it."
    snippet "$iam_cmd"
    return 0
  fi
  info "Create the IAM trust policy, permissions policy, role, and inline policy:"
  confirm_and_run "IAM role creation" "$iam_cmd"

  AWS_ROLE_ARN="arn:aws:iam::${AWS_ACCOUNT_ID:-ACCOUNT_ID}:role/${role}"
}

# ────────────────────────── step 4: install advice ─────────────────────
advise_install() {
  heading "Install the PgDog control plane"
  detect_aws_alb_subnets
  local install_cmd="helm upgrade --install $RELEASE $CHART \\
--namespace $NAMESPACE --create-namespace"
  if [[ -n "$VALUES_FILE" ]]; then
    install_cmd="$install_cmd \\
-f $VALUES_FILE"
  else
    install_cmd="$install_cmd \\
--set ingress.mode=$MODE"
    [[ -n "$HOST" ]] && install_cmd="$install_cmd \\
--set ingress.host=$HOST"
    if [[ "$MODE" == "gateway" ]]; then
      install_cmd="$install_cmd \\
--set ingress.gateway.name=${GATEWAY_NAME:-<GATEWAY_NAME>} \\
--set ingress.gateway.namespace=${GATEWAY_NAMESPACE:-<GATEWAY_NAMESPACE>}"
      [[ -n "$GATEWAY_SECTION" ]] && install_cmd="$install_cmd \\
--set ingress.gateway.sectionName=$GATEWAY_SECTION"
    fi
    if [[ -n "$GH_CLIENT_ID" ]]; then
      install_cmd="$install_cmd \\
--set control.config.auth.redirect_base_url=https://$HOST \\
--set control.config.auth.github.client_id=$GH_CLIENT_ID \\
--set control.config.auth.github.client_secret=$GH_CLIENT_SECRET"
      [[ -n "$GH_ALLOWED_ORGS" ]] && install_cmd="$install_cmd \\
--set control.config.auth.github.allowed_orgs[0]=$GH_ALLOWED_ORGS"
    fi
  fi
  if [[ -n "$AWS_ROLE_ARN" ]]; then
    install_cmd="$install_cmd \\
--set-string control.aws.roleArn=$AWS_ROLE_ARN"
    [[ -n "$AWS_REGION" ]] && install_cmd="$install_cmd \\
--set-string control.aws.region=$AWS_REGION"
  fi
  if [[ -n "$AWS_CERT_ARN" ]]; then
    install_cmd="$install_cmd \\
--set-string ingress.aws.certificateArn=$AWS_CERT_ARN"
  fi
  if [[ -n "$AWS_ALB_SUBNETS" ]]; then
    install_cmd="$install_cmd \\
--set-json 'ingress.aws.subnets=\"$AWS_ALB_SUBNETS\"'"
  fi
  install_cmd="$install_cmd \\
--set-string 'control.rbac.writeNamespaces[0]=$NAMESPACE'"
  info "Add the chart repo, then install the release:"
  confirm_and_run "PgDog control plane installation" "helm repo add $REPO_NAME $REPO_URL
helm repo update
$install_cmd"
  if [[ -n "$GH_CLIENT_ID" ]]; then
    warn "The client secret is passed via --set, so it will appear in your shell history."
  fi
  info "Watch the workloads come up with:"
  snippet "kubectl -n $NAMESPACE get pods -l app.kubernetes.io/instance=$RELEASE -w"
  if [[ "$MODE" == "nginx" ]]; then
    info "Wait for cert-manager to issue the TLS certificate. This can take a minute or two."
  else
    info "The ALB is created during install; create the DNS record (next step) once"
    info "its address appears."
  fi
}

# ───────────────────────────── step 5: dns advice ──────────────────────
# Read the public address traffic should point at: the ingress-nginx
# LoadBalancer (nginx mode) or the ALB fronting the chart's Ingress (aws).
detect_target() {
  case "$MODE" in
    nginx)
      kubectl -n ingress-nginx get svc ingress-nginx-controller \
        -o jsonpath='{.status.loadBalancer.ingress[0].ip}{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null
      ;;
    aws)
      kubectl -n "$NAMESPACE" get ingress "${RELEASE}-control" \
        -o jsonpath='{.status.loadBalancer.ingress[0].hostname}{.status.loadBalancer.ingress[0].ip}' 2>/dev/null
      ;;
    gateway)
      [[ -n "$GATEWAY_NAME" && -n "$GATEWAY_NAMESPACE" ]] || return 0
      kubectl -n "$GATEWAY_NAMESPACE" get gateway "$GATEWAY_NAME" \
        -o jsonpath='{.status.addresses[0].value}' 2>/dev/null
      ;;
  esac
}

# Lists Route53 hosted zones (read-only) and lets the user pick one.
# On success sets ZONE_ID and ZONE_NAME (zone name without trailing dot).
choose_hosted_zone() {
  info "Fetching Route53 hosted zones…"
  local lines
  if ! lines=$(aws route53 list-hosted-zones \
       --query 'HostedZones[].[Id,Name,Config.PrivateZone]' --output text 2>/dev/null); then
    warn "Could not list hosted zones — check your AWS credentials / permissions."
    return 1
  fi
  if [[ -z "$lines" ]]; then warn "No hosted zones found in this AWS account."; return 1; fi

  local -a ids=() names=() privs=()
  while IFS=$'\t' read -r id name priv; do
    [[ -z "$id" ]] && continue
    ids+=("${id#/hostedzone/}"); names+=("${name%.}"); privs+=("$priv")
  done <<< "$lines"

  printf "\n"
  local i
  for i in "${!ids[@]}"; do
    local tag=""; [[ "${privs[$i]}" == "True" ]] && tag="${DIM}(private)${RESET}"
    printf "    ${BOLD}%2d)${RESET} %-32s ${DIM}%s${RESET} %s\n" \
      "$((i + 1))" "${names[$i]}" "${ids[$i]}" "$tag"
  done

  prompt_select "Select a hosted zone" "${#ids[@]}" 1
  local choice="$PROMPT_VALUE"
  ZONE_ID="${ids[$((choice - 1))]}"; ZONE_NAME="${names[$((choice - 1))]}"
  ok "Selected zone: ${BOLD}${ZONE_NAME}${RESET} (${ZONE_ID})"
}

advise_dns() {
  heading "DNS  ${DIM}(point your hostname at the load balancer)${RESET}"
  prompt_dns_provider

  # Read-only helper: offer the hosted-zone list so the Route53 command has a real id.
  if [[ "$DNS_PROVIDER" == "route53" ]] && have aws && [[ -z "$ZONE_ID" ]] && (( ASSUME_YES == 0 )); then
    choose_hosted_zone || true
  fi

  local zone="${ZONE_ID:-<HOSTED_ZONE_ID>}"
  local record="${HOST:-control.example.com}"

  # Read the live LB address if the cluster is reachable; else use a placeholder.
  local target=""
  if (( CLUSTER_OK )); then target="$(detect_target || true)"; fi

  local rtype target_known=0
  if [[ -n "$target" ]]; then
    target_known=1
    info "Detected load balancer address: ${BOLD}${target}${RESET}"
    if [[ "$target" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then rtype="A"; else rtype="CNAME"; fi
  else
    info "Get the load balancer address once the install has reconciled:"
    case "$MODE" in
      nginx) snippet "kubectl -n ingress-nginx get svc ingress-nginx-controller -w" ;;
      aws)   snippet "kubectl -n $NAMESPACE get ingress ${RELEASE}-control -w" ;;
    esac
    target="<LB_ADDRESS>"
    rtype="CNAME"
    info "Use record type ${BOLD}A${RESET} if the address is an IP, ${BOLD}CNAME${RESET} if it's a hostname."
  fi

  # nginx needs the record live before install so cert-manager's HTTP-01 passes.
  if [[ "$MODE" == "nginx" ]]; then
    if (( target_known )); then
      info "cert-manager needs ${BOLD}${record}${RESET} to resolve before issuing the TLS certificate."
    else
      info "cert-manager needs ${BOLD}${record}${RESET} to resolve to the ingress-nginx LoadBalancer"
      info "before it can complete the Let's Encrypt HTTP-01 challenge. Install ingress-nginx"
      info "first, read its external address, then create this record."
    fi
  fi

  if [[ "$rtype" == "CNAME" && "${record%.}" == "${ZONE_NAME:-}" ]]; then
    warn "A CNAME at the zone apex (${record}) is invalid — use a subdomain or a Route53 ALIAS record."
  fi

  if [[ "$DNS_PROVIDER" == "manual" ]]; then
    info "Create this DNS record with your DNS provider:"
    snippet "Name: $record
Type: $rtype
Value: $target
TTL: 300"
    confirm_done "the DNS record exists"
    return 0
  fi

  local dns_cmd="CHANGE_ID=\$(aws route53 change-resource-record-sets \\
--hosted-zone-id $zone \\
--change-batch '{
    \"Comment\": \"PgDog control plane dashboard\",
    \"Changes\": [{
      \"Action\": \"UPSERT\",
      \"ResourceRecordSet\": {
        \"Name\": \"$record\",
        \"Type\": \"$rtype\",
        \"TTL\": 300,
        \"ResourceRecords\": [{ \"Value\": \"$target\" }]
      }
    }]
  }' \\
--query 'ChangeInfo.Id' \\
--output text)

aws route53 wait resource-record-sets-changed --id \"\$CHANGE_ID\"
echo \"\$CHANGE_ID\""
  if [[ "$zone" == "<HOSTED_ZONE_ID>" || "$target" == "<LB_ADDRESS>" ]]; then
    warn "DNS command still has placeholders; not running it."
    snippet "$dns_cmd"
    return 0
  fi
  info "Creating the Route53 record and waiting for propagation:"
  confirm_and_run "Route53 DNS record creation" "$dns_cmd"
}

# ──────────────────────────── args / main ──────────────────────────────
usage() {
  cat <<EOF
PgDog EE Control Plane installer

Usage: $0 [options]
  -r, --release NAME    Helm release name              (default: pgdog-control)
  -n, --namespace NS    Target namespace               (default: default)
  -m, --mode MODE       Ingress mode: nginx | aws | gateway
                                                    (prompted if omitted)
      --host HOST       External hostname (ingress.host)
  -f, --values FILE     values.yaml referenced in the helm install command
      --email EMAIL     ACME email shown in the ClusterIssuer manifest
      --aws-cluster NAME
                       EKS cluster name for OIDC / IRSA checks
      --aws-region REGION
                       AWS region for EKS and the control pod
      --aws-role-name NAME
                       IAM role name to create          (default: pgdog-<namespace>-<cluster>)
      --aws-role-arn ARN
                       Existing IAM role ARN to set as control.aws.roleArn
      --acm-cert-arn ARN
                       ACM certificate ARN for AWS ALB HTTPS
  -y, --yes             Non-interactive: assume defaults and run commands
  -h, --help            Show this help

This tool inspects your machine and cluster, shows each mutating helm /
kubectl / aws command block, and runs it after you type "confirm".
With --yes, generated command blocks run automatically.
The DNS step may list Route53 hosted zones to put a real zone id into the
Route53 change.

Testing: set FAKE_MISSING="aws jq" to force those tools to report as
missing without changing your PATH (see test/ for a full harness).
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -r|--release)   RELEASE=$2;     shift 2 ;;
      -n|--namespace) NAMESPACE=$2; NAMESPACE_FROM_FLAG=1; shift 2 ;;
      -m|--mode)      MODE=$2; MODE_FROM_FLAG=1; shift 2 ;;
      --host)         HOST=$2;        shift 2 ;;
      -f|--values)    VALUES_FILE=$2; shift 2 ;;
      --email)        ACME_EMAIL=$2;  shift 2 ;;
      --aws-cluster)  AWS_CLUSTER=$2; shift 2 ;;
      --aws-region)   AWS_REGION=$2;  shift 2 ;;
      --aws-role-name) AWS_ROLE_NAME=$2; AWS_ROLE_NAME_FROM_FLAG=1; CONFIGURE_AWS=1; shift 2 ;;
      --aws-role-arn) AWS_ROLE_ARN=$2; CONFIGURE_AWS=1; shift 2 ;;
      --acm-cert-arn) AWS_CERT_ARN=$2; shift 2 ;;
      -y|--yes)       ASSUME_YES=1;   shift   ;;
      -h|--help)      usage; exit 0 ;;
      *) die "Unknown option: $1" ;;
    esac
  done
  if (( MODE_FROM_FLAG )); then
    case "$MODE" in nginx|aws|gateway) ;; *) die "Invalid --mode: $MODE (use nginx, aws, or gateway)" ;; esac
  fi
  if ! valid_namespace "$NAMESPACE"; then
    die "Invalid --namespace: $NAMESPACE"
  fi
}

main() {
  parse_args "$@"
  # When piped (e.g. `curl … | bash`), stdin is the script itself, so prompts
  # would hit EOF. Reattach stdin to the terminal — but only if /dev/tty is
  # actually openable (a failed `exec` redirect would kill the shell).
  if [[ ! -t 0 ]] && (exec </dev/tty) 2>/dev/null; then exec </dev/tty; fi
  banner
  check_local_deps
  check_cluster_deps   # scans controllers, proposes the ingress mode, mode-specific checks
  prompt_namespace
  prompt_gateway
  prompt_host
  setup_github_oauth
  setup_aws_acm_tls
  setup_aws_access
  printf "\n  ${DIM}release=%s  namespace=%s  mode=%s%s${RESET}\n" \
    "$RELEASE" "$NAMESPACE" "$MODE" "${HOST:+  host=$HOST}"
  advise_prereqs
  advise_aws_iam_role
  # nginx: DNS must resolve BEFORE the chart install so cert-manager's
  # HTTP-01 challenge can complete. aws: the ALB only exists after install,
  # so DNS comes last.
  if [[ "$MODE" == "nginx" ]]; then
    advise_dns
    advise_install
  else
    advise_install
    advise_dns
  fi
  printf "\n${GREEN}${BOLD}Install complete.${RESET}\n"
  [[ -n "$HOST" ]] && boxed_line "PgDog Control Plane: https://$HOST"
}

main "$@"
