#!/usr/bin/env bash
#
# install.sh — read-only install ADVISOR for the PgDog EE Control Plane.
#
# This script changes NOTHING. It only inspects and advises:
#   1. verify local CLI tools
#   2. scan the cluster for ingress controllers, propose an ingress mode,
#      then check the remaining per-mode deps (read-only)
#   3. print the commands to install any missing prerequisites
#      (ingress-nginx, cert-manager, a Let's Encrypt ClusterIssuer)
#   4. print the `helm` commands to install the chart
#   5. list Route53 hosted zones (read-only) and print the `aws` command
#      to create the DNS record pointing the hostname at the load balancer
#
# Every mutating action is emitted as a copy-pasteable command for you to
# review and run yourself.
#
set -euo pipefail

# ──────────────────────────── configuration ────────────────────────────
REPO_NAME="pgdogdev-ee"
REPO_URL="https://helm-ee.pgdog.dev"
CHART="pgdogdev-ee/pgdog-control"

RELEASE="control"
NAMESPACE="default"
MODE=""               # nginx | aws  (chosen interactively when unset)
MODE_FROM_FLAG=0
HOST=""
VALUES_FILE=""
ACME_EMAIL=""
ASSUME_YES=0

# state filled in by the checks
MISSING_NGINX=0; MISSING_CERTMGR=0; MISSING_ISSUER=0
HAVE_NGINX=0; HAVE_ALB=0; HAVE_GATEWAY=0
CLUSTER_OK=1
REQUIRED_MISSING=0
ZONE_ID=""; ZONE_NAME=""
GH_CLIENT_ID=""; GH_CLIENT_SECRET=""; GH_ALLOWED_ORGS=""
GATEWAY_NAME=""; GATEWAY_NAMESPACE=""; GATEWAY_SECTION=""
STEP=0

# ───────────────────────────── colors / ui ─────────────────────────────
if [[ -t 1 ]] && command -v tput >/dev/null 2>&1 && [[ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]]; then
  BOLD=$(tput bold); RESET=$(tput sgr0); DIM=$(tput dim)
  RED=$(tput setaf 1); GREEN=$(tput setaf 2); YELLOW=$(tput setaf 3)
  BLUE=$(tput setaf 4); CYAN=$(tput setaf 6)
else
  BOLD=""; RESET=""; DIM=""; RED=""; GREEN=""; YELLOW=""; BLUE=""; CYAN=""
fi
CHECK="✔"; CROSS="✘"; WARN_SYM="⚠"; INFO_SYM="ℹ"

banner() {
  local bar; bar=$(printf '─%.0s' {1..49})
  # Inner width is 49; lines are: 3-space margin + text + trailing pad.
  # Title text is 40 cols (→ 6 trailing), subtitle is 44 cols (→ 2 trailing).
  printf "\n${CYAN}${BOLD}╭%s╮${RESET}\n" "$bar"
  printf   "${CYAN}${BOLD}│${RESET}   ${BOLD}PgDog EE · Control Plane Install Advisor${RESET}      ${CYAN}${BOLD}│${RESET}\n"
  printf   "${CYAN}${BOLD}│${RESET}   ${DIM}read-only — prints commands, changes nothing${RESET}  ${CYAN}${BOLD}│${RESET}\n"
  printf   "${CYAN}${BOLD}╰%s╯${RESET}\n" "$bar"
}

step() { printf "\n${BLUE}${BOLD}%s${RESET}  ${BOLD}%s${RESET}\n" "$1" "$2"; }
# heading <title> — a numbered step; counter advances so the order can vary by mode.
heading() { STEP=$((STEP + 1)); step "Step $STEP" "$1"; }
info() { printf "  ${BLUE}${INFO_SYM}${RESET} %s\n" "$1"; }
ok()   { printf "  ${GREEN}${CHECK}${RESET} %s\n" "$1"; }
warn() { printf "  ${YELLOW}${WARN_SYM}${RESET} %s\n" "$1"; }
die()  { printf "\n${RED}${BOLD}Aborting:${RESET} %s\n" "$1" >&2; exit 1; }

# snippet <multi-line-string> — render a copy-paste command/manifest block
snippet() {
  printf "\n"
  while IFS= read -r _l; do printf "      ${BOLD}%s${RESET}\n" "$_l"; done <<< "$1"
  printf "\n"
}

# row <ok|bad|warn> <name> <detail>
row() {
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
  local r; printf "  ${YELLOW}?${RESET} %s ${DIM}[y/N]${RESET} " "$1"; read -r r
  [[ "$r" =~ ^[Yy]$ ]]
}

# Best-effort open a URL in the host browser (no-op if no opener available).
open_url() {
  if   have open;     then open "$1"     >/dev/null 2>&1 || true
  elif have xdg-open; then xdg-open "$1" >/dev/null 2>&1 || true
  fi
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
  else                          default="nginx";   reason="no controller detected"
  fi

  info "Proposed ingress mode: ${BOLD}${default}${RESET} ${DIM}(${reason})${RESET}"
  if (( ASSUME_YES )); then MODE="$default"; ok "Ingress mode: ${BOLD}${MODE}${RESET}"; return 0; fi

  local dnum
  case "$default" in aws) dnum=2 ;; gateway) dnum=3 ;; *) dnum=1 ;; esac
  printf "    ${BOLD}1)${RESET} nginx     ${DIM}ingress-nginx + cert-manager (Let's Encrypt TLS)${RESET}\n"
  printf "    ${BOLD}2)${RESET} aws       ${DIM}AWS Load Balancer Controller (ALB + ACM TLS)${RESET}\n"
  printf "    ${BOLD}3)${RESET} gateway   ${DIM}Gateway API HTTPRoute (TLS at the Gateway)${RESET}\n"
  local choice
  while true; do
    printf "  ${YELLOW}?${RESET} Press enter to accept ${BOLD}%s${RESET}, or choose 1/2/3 ${DIM}[%s]${RESET} " "$default" "$dnum"
    read -r choice
    case "${choice:-$dnum}" in
      1|nginx)   MODE="nginx";   break ;;
      2|aws)     MODE="aws";     break ;;
      3|gateway) MODE="gateway"; break ;;
      *) warn "Enter 1 (nginx), 2 (aws), or 3 (gateway)." ;;
    esac
  done
  ok "Ingress mode: ${BOLD}${MODE}${RESET}"
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
    line=$(kubectl get gateways.gateway.networking.k8s.io -A --no-headers 2>/dev/null | head -n1 || true)
    def_ns=$(awk '{print $1}' <<< "$line")
    def_name=$(awk '{print $2}' <<< "$line")
    [[ -n "$def_name" ]] && info "Detected Gateway: ${BOLD}${def_name}${RESET} in ${BOLD}${def_ns}${RESET}"
  fi
  printf "  ${YELLOW}?${RESET} Gateway name ${DIM}[%s]${RESET}: " "${def_name:-required}"
  read -r GATEWAY_NAME; GATEWAY_NAME="${GATEWAY_NAME:-$def_name}"
  printf "  ${YELLOW}?${RESET} Gateway namespace ${DIM}[%s]${RESET}: " "${def_ns:-required}"
  read -r GATEWAY_NAMESPACE; GATEWAY_NAMESPACE="${GATEWAY_NAMESPACE:-$def_ns}"
  printf "  ${YELLOW}?${RESET} Listener sectionName ${DIM}(optional, blank = all)${RESET}: "
  read -r GATEWAY_SECTION
  if [[ -z "$GATEWAY_NAME" || -z "$GATEWAY_NAMESPACE" ]]; then
    warn "Gateway name and namespace are required for gateway mode."
  fi
}

# ───────────────────────── hostname selection ──────────────────────────
# Asks for the external hostname. When the AWS CLI is available it first
# lists the Route53 hosted zones (read-only) so you can pick one and build
# the host from it; the chosen zone is remembered and reused in the DNS step.
prompt_host() {
  if [[ -n "$HOST" || -n "$VALUES_FILE" ]]; then return 0; fi
  if (( ASSUME_YES )); then return 0; fi

  step "Hostname" "External hostname for the dashboard (ingress.host)"
  if have aws && choose_hosted_zone; then
    printf "  ${YELLOW}?${RESET} Record hostname ${DIM}[pgdog.%s]${RESET}: " "$ZONE_NAME"
    read -r HOST
    HOST="${HOST:-pgdog.$ZONE_NAME}"
  else
    have aws || info "AWS CLI not found — enter the hostname manually."
    printf "  ${YELLOW}?${RESET} External hostname, e.g. control.acme.com: "
    read -r HOST
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
  printf "  ${YELLOW}?${RESET} GitHub org for the OAuth app ${DIM}[%s]${RESET}: " "${default_org:-blank = personal account}"
  read -r org
  org="${org:-$default_org}"
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
  printf "  ${YELLOW}?${RESET} Client ID: ";     read -r GH_CLIENT_ID
  printf "  ${YELLOW}?${RESET} Client secret: "; read -r GH_CLIENT_SECRET
  [[ -n "$org" ]] && GH_ALLOWED_ORGS="$org"

  if [[ -n "$GH_CLIENT_ID" && -n "$GH_CLIENT_SECRET" ]]; then
    ok "GitHub OAuth captured — config will be shown with the install step."
  else
    warn "Missing client id/secret — GitHub OAuth will be omitted."
    GH_CLIENT_ID=""; GH_CLIENT_SECRET=""
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
  if kubectl get ingressclass nginx >/dev/null 2>&1 \
     || kubectl -n ingress-nginx get deploy ingress-nginx-controller >/dev/null 2>&1; then
    HAVE_NGINX=1; row ok "ingress-nginx" "controller present"
  else
    row warn "ingress-nginx" "not detected"
  fi
  if kubectl get ingressclass alb >/dev/null 2>&1 \
     || kubectl -n kube-system get deploy aws-load-balancer-controller >/dev/null 2>&1; then
    HAVE_ALB=1; row ok "AWS LB Controller" "present"
  else
    row warn "AWS LB Controller" "not detected"
  fi
  # Gateway API: HTTPRoute mode needs the gateway.networking.k8s.io CRDs and
  # at least one Gateway resource for the HTTPRoute to attach to. A controller
  # being installed shows up as a GatewayClass but is not itself a Gateway.
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
  if kubectl cluster-info >/dev/null 2>&1; then
    row ok "kube API reachable" "context: $(kubectl config current-context 2>/dev/null || echo '?')"
  else
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
  snippet "helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update
helm install ingress-nginx ingress-nginx/ingress-nginx \\
  --namespace ingress-nginx --create-namespace \\
  --set controller.service.type=LoadBalancer
kubectl -n ingress-nginx get svc ingress-nginx-controller -w   # note the external address"
}

advise_cert_manager() {
  info "Install cert-manager:"
  snippet "helm repo add jetstack https://charts.jetstack.io
helm repo update
helm install cert-manager jetstack/cert-manager \\
  --namespace cert-manager --create-namespace \\
  --set crds.enabled=true"
}

advise_clusterissuer() {
  local email="${ACME_EMAIL:-your-email@example.com}"
  info "Create a Let's Encrypt ClusterIssuer (edit the email):"
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

# ────────────────────────── step 4: install advice ─────────────────────
advise_install() {
  heading "Install the PgDog control plane"
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
  info "Add the chart repo, then install the release:"
  snippet "helm repo add $REPO_NAME $REPO_URL
helm repo update
$install_cmd"
  if [[ -n "$GH_CLIENT_ID" ]]; then
    warn "The client secret is passed via --set, so it will appear in your shell history."
  fi
  info "Watch the workloads come up:"
  snippet "kubectl -n $NAMESPACE get pods -l app.kubernetes.io/instance=$RELEASE -w"
  if [[ "$MODE" == "nginx" ]]; then
    info "Make sure the DNS record above already resolves — cert-manager issues the"
    info "certificate during install and will retry until the hostname points here."
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

  local choice
  printf "  ${YELLOW}?${RESET} Select a hosted zone ${DIM}[1-%d, default 1]${RESET}: " "${#ids[@]}"
  read -r choice
  choice="${choice:-1}"
  if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#ids[@]} )); then
    warn "Invalid selection."; return 1
  fi
  ZONE_ID="${ids[$((choice - 1))]}"; ZONE_NAME="${names[$((choice - 1))]}"
  ok "Selected zone: ${BOLD}${ZONE_NAME}${RESET} (${ZONE_ID})"
}

advise_dns() {
  heading "DNS  ${DIM}(point your hostname at the load balancer)${RESET}"

  # Read-only helper: offer the hosted-zone list so the command has a real id.
  if have aws && [[ -z "$ZONE_ID" ]] && (( ASSUME_YES == 0 )); then
    choose_hosted_zone || true
  elif ! have aws; then
    info "AWS CLI not found — fill in the hosted zone id manually below."
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
    warn "Create this DNS record BEFORE installing the chart (next step)."
    if (( target_known )); then
      info "The ingress-nginx LoadBalancer is already up (address above), so create the"
      info "record now — cert-manager needs ${BOLD}${record}${RESET} to resolve before issuing the cert."
    else
      info "cert-manager needs ${BOLD}${record}${RESET} to resolve to the ingress-nginx LoadBalancer"
      info "before it can complete the Let's Encrypt HTTP-01 challenge. Install ingress-nginx"
      info "first, read its external address, then create this record."
    fi
  fi

  if [[ "$rtype" == "CNAME" && "${record%.}" == "${ZONE_NAME:-}" ]]; then
    warn "A CNAME at the zone apex (${record}) is invalid — use a subdomain or a Route53 ALIAS record."
  fi

  info "Create the Route53 record:"
  snippet "aws route53 change-resource-record-sets \\
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
  }'"
  info "The command prints a change id; wait for it to propagate with:"
  snippet "aws route53 wait resource-record-sets-changed --id <CHANGE_ID>"
}

# ──────────────────────────── args / main ──────────────────────────────
usage() {
  cat <<EOF
PgDog EE Control Plane install advisor (read-only — changes nothing)

Usage: $0 [options]
  -r, --release NAME    Helm release name              (default: control)
  -n, --namespace NS    Target namespace               (default: default)
  -m, --mode MODE       Ingress mode: nginx | aws      (prompted if omitted)
      --host HOST       External hostname (ingress.host)
  -f, --values FILE     values.yaml referenced in the printed helm command
      --email EMAIL     ACME email shown in the ClusterIssuer manifest
  -y, --yes             Non-interactive: assume defaults, skip all prompts
  -h, --help            Show this help

This tool inspects your machine and cluster (read-only) and PRINTS the
helm / kubectl / aws commands to run. It never installs, applies, or
creates anything. Step 5 may list Route53 hosted zones (read-only) to put
a real zone id into the printed DNS command.

Testing: set FAKE_MISSING="aws jq" to force those tools to report as
missing without changing your PATH (see test/ for a full harness).
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -r|--release)   RELEASE=$2;     shift 2 ;;
      -n|--namespace) NAMESPACE=$2;   shift 2 ;;
      -m|--mode)      MODE=$2; MODE_FROM_FLAG=1; shift 2 ;;
      --host)         HOST=$2;        shift 2 ;;
      -f|--values)    VALUES_FILE=$2; shift 2 ;;
      --email)        ACME_EMAIL=$2;  shift 2 ;;
      -y|--yes)       ASSUME_YES=1;   shift   ;;
      -h|--help)      usage; exit 0 ;;
      *) die "Unknown option: $1" ;;
    esac
  done
  if (( MODE_FROM_FLAG )); then
    case "$MODE" in nginx|aws|gateway) ;; *) die "Invalid --mode: $MODE (use nginx, aws, or gateway)" ;; esac
  fi
}

main() {
  parse_args "$@"
  banner
  check_local_deps
  check_cluster_deps   # scans controllers, proposes the ingress mode, mode-specific checks
  prompt_gateway
  prompt_host
  setup_github_oauth
  printf "\n  ${DIM}release=%s  namespace=%s  mode=%s%s${RESET}\n" \
    "$RELEASE" "$NAMESPACE" "$MODE" "${HOST:+  host=$HOST}"
  advise_prereqs
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
  printf "\n${GREEN}${BOLD}Advice complete.${RESET} ${DIM}Review the commands above and run them yourself.${RESET}\n"
}

main "$@"
