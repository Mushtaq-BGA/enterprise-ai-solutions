#!/usr/bin/env bash
# Copyright (C) 2025-2026 Intel Corporation
# SPDX-License-Identifier: Apache-2.0
# =============================================================================
# add-custom-dns.sh — Add custom DNS names to Envoy Gateway
# =============================================================================
# This script configures the Envoy Gateway to accept custom DNS hostnames
# that don't match the wildcard certificate pattern.
#
# Usage:
#   ./add-custom-dns.sh <hostname1> [hostname2] [hostname3] ...
#
# Examples:
#   ./add-custom-dns.sh keycloak-prod.example.com
#   ./add-custom-dns.sh keycloak-prod.example.com grafana-prod.example.com api-prod.example.com
#
# What it does:
#   1. Adds each hostname to the gateway TLS certificate (cert-manager)
#   2. Waits for cert-manager to reissue the certificate
#   3. Creates a dedicated HTTPS listener for each hostname on the gateway
#   4. Verifies the configuration
#
# Why you need this:
#   Wildcard certificates like *.example.com only match one DNS level.
#   Hostnames like "keycloak-prod.example.com" won't match because
#   "keycloak-prod" is treated as a single subdomain with hyphens,
#   not as nested domains.
# =============================================================================

set -euo pipefail

# ── Configuration ────────────────────────────────────────────────────────────
NAMESPACE="${ENVOY_GATEWAY_NAMESPACE:-envoy-gateway-system}"
GATEWAY_NAME="${GATEWAY_NAME:-eg-gateway}"
CERT_NAME="${GATEWAY_CERT_NAME:-gateway-tls-cert}"
CERT_SECRET_NAME="${GATEWAY_CERT_SECRET:-gateway-tls}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# ── Helper functions ─────────────────────────────────────────────────────────
log_info() { echo -e "${BLUE}ℹ${NC} $*"; }
log_success() { echo -e "${GREEN}✓${NC} $*"; }
log_warning() { echo -e "${YELLOW}⚠${NC} $*"; }
log_error() { echo -e "${RED}✗${NC} $*" >&2; }

error_exit() {
  log_error "$1"
  exit 1
}

# ── Preflight checks ─────────────────────────────────────────────────────────
check_prerequisites() {
  if ! command -v kubectl &>/dev/null; then
    error_exit "kubectl not found in PATH. Install kubectl first."
  fi

  if ! command -v openssl &>/dev/null; then
    error_exit "openssl not found in PATH. Install openssl first."
  fi

  if ! kubectl cluster-info --request-timeout=5s &>/dev/null; then
    error_exit "kubectl cannot reach the cluster. Check KUBECONFIG or run:\n  export KUBECONFIG=~/.kube/config"
  fi

  # Check if cert-manager is installed
  if ! kubectl get crd certificates.cert-manager.io &>/dev/null; then
    error_exit "cert-manager CRDs not found. Is cert-manager installed?"
  fi

  # Check if gateway exists
  if ! kubectl get gateway "$GATEWAY_NAME" -n "$NAMESPACE" &>/dev/null; then
    error_exit "Gateway '$GATEWAY_NAME' not found in namespace '$NAMESPACE'"
  fi

  # Check if certificate exists
  if ! kubectl get certificate "$CERT_NAME" -n "$NAMESPACE" &>/dev/null; then
    error_exit "Certificate '$CERT_NAME' not found in namespace '$NAMESPACE'"
  fi
}

# ── Validate hostname ────────────────────────────────────────────────────────
validate_hostname() {
  local hostname="$1"

  # Basic DNS name validation
  if [[ ! "$hostname" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?)*$ ]]; then
    log_error "Invalid hostname: $hostname"
    return 1
  fi

  return 0
}

# ── Check if hostname already exists in certificate ─────────────────────────
hostname_in_cert() {
  local hostname="$1"
  local existing_dns

  existing_dns=$(kubectl get certificate "$CERT_NAME" -n "$NAMESPACE" \
    -o jsonpath='{.spec.dnsNames[*]}' 2>/dev/null || echo "")

  if [[ " $existing_dns " == *" $hostname "* ]]; then
    return 0  # Already exists
  fi
  return 1  # Not found
}

# ── Check if listener already exists in gateway ─────────────────────────────
listener_exists() {
  local hostname="$1"
  local existing_hostnames

  existing_hostnames=$(kubectl get gateway "$GATEWAY_NAME" -n "$NAMESPACE" \
    -o jsonpath='{.spec.listeners[*].hostname}' 2>/dev/null || echo "")

  if [[ " $existing_hostnames " == *" $hostname "* ]]; then
    return 0  # Already exists
  fi
  return 1  # Not found
}

# ── Add hostname to certificate ─────────────────────────────────────────────
add_to_certificate() {
  local hostname="$1"

  if hostname_in_cert "$hostname"; then
    log_warning "Hostname '$hostname' already in certificate, skipping"
    return 0
  fi

  log_info "Adding '$hostname' to certificate '$CERT_NAME'..."

  kubectl patch certificate "$CERT_NAME" -n "$NAMESPACE" --type=json -p="[
    {\"op\": \"add\", \"path\": \"/spec/dnsNames/-\", \"value\": \"$hostname\"}
  ]" &>/dev/null

  log_success "Added '$hostname' to certificate"
}

# ── Wait for certificate to be ready ────────────────────────────────────────
wait_for_certificate() {
  log_info "Waiting for certificate to be reissued (timeout: 120s)..."

  if kubectl wait --for=condition=Ready certificate/"$CERT_NAME" -n "$NAMESPACE" --timeout=120s &>/dev/null; then
    log_success "Certificate is ready"
    return 0
  else
    log_error "Certificate failed to become ready within timeout"
    return 1
  fi
}

# ── Add gateway listener ────────────────────────────────────────────────────
add_gateway_listener() {
  local hostname="$1"

  if listener_exists "$hostname"; then
    log_warning "Listener for '$hostname' already exists, skipping"
    return 0
  fi

  # Generate listener name from hostname (sanitize for k8s naming)
  local listener_name
  listener_name="https-$(echo "$hostname" | cut -d'.' -f1 | tr '[:upper:]' '[:lower:]' | tr '_' '-' | sed 's/[^a-z0-9-]//g')"

  log_info "Adding gateway listener '$listener_name' for '$hostname'..."

  kubectl patch gateway "$GATEWAY_NAME" -n "$NAMESPACE" --type=json -p="[
    {
      \"op\": \"add\",
      \"path\": \"/spec/listeners/-\",
      \"value\": {
        \"name\": \"$listener_name\",
        \"protocol\": \"HTTPS\",
        \"port\": 443,
        \"hostname\": \"$hostname\",
        \"allowedRoutes\": {
          \"namespaces\": {
            \"from\": \"All\"
          }
        },
        \"tls\": {
          \"mode\": \"Terminate\",
          \"certificateRefs\": [
            {
              \"group\": \"\",
              \"kind\": \"Secret\",
              \"name\": \"$CERT_SECRET_NAME\"
            }
          ]
        }
      }
    }
  ]" &>/dev/null

  log_success "Added listener '$listener_name' for '$hostname'"
}

# ── Verify configuration ────────────────────────────────────────────────────
verify_configuration() {
  local hostnames=("$@")

  log_info "Verifying configuration..."

  # Check certificate SANs
  local cert_sans
  cert_sans=$(kubectl get secret -n "$NAMESPACE" "$CERT_SECRET_NAME" \
    -o jsonpath='{.data.tls\.crt}' 2>/dev/null | base64 -d | \
    openssl x509 -noout -text 2>/dev/null | \
    grep -A1 "Subject Alternative Name" | tail -1 | tr ',' '\n' | \
    sed 's/^[[:space:]]*DNS://' | tr -d ' ')

  echo ""
  echo "Certificate SANs:"
  echo "$cert_sans" | while read -r san; do
    [[ -z "$san" ]] && continue
    echo "  • $san"
  done

  # Check gateway listeners
  echo ""
  echo "Gateway Listeners:"
  kubectl get gateway "$GATEWAY_NAME" -n "$NAMESPACE" \
    -o jsonpath='{range .spec.listeners[*]}{.name}{"\t"}{.hostname}{"\n"}{end}' | \
    column -t -s$'\t' | sed 's/^/  • /'

  # Verify each hostname
  echo ""
  local all_verified=true
  for hostname in "${hostnames[@]}"; do
    if echo "$cert_sans" | grep -q "^$hostname$"; then
      log_success "Hostname '$hostname' verified in certificate"
    else
      log_error "Hostname '$hostname' NOT found in certificate"
      all_verified=false
    fi
  done

  if [[ "$all_verified" == "true" ]]; then
    echo ""
    log_success "All hostnames configured successfully!"
  else
    echo ""
    log_error "Some hostnames failed verification"
    return 1
  fi
}

# ── Show test command ───────────────────────────────────────────────────────
show_test_commands() {
  local hostnames=("$@")

  local gateway_ip
  gateway_ip=$(kubectl get svc -n "$NAMESPACE" \
    -l gateway.envoyproxy.io/owning-gateway-name \
    -o jsonpath='{.items[0].status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")

  if [[ -z "$gateway_ip" ]]; then
    log_warning "Could not determine gateway IP"
    return
  fi

  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "Test your configuration:"
  echo ""
  echo "Gateway IP: $gateway_ip"
  echo ""

  for hostname in "${hostnames[@]}"; do
    echo "# Test $hostname"
    echo "curl -sk --resolve \"$hostname:443:$gateway_ip\" \"https://$hostname/\""
    echo ""
  done

  echo "Add to /etc/hosts:"
  echo "echo \"$gateway_ip $(printf '%s ' "${hostnames[@]}")\" | sudo tee -a /etc/hosts"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

# ── Usage ────────────────────────────────────────────────────────────────────
usage() {
  cat <<EOF
Usage: $0 <hostname1> [hostname2] [hostname3] ...

Add custom DNS names to Envoy Gateway certificate and listeners.

Examples:
  $0 keycloak-prod.example.com
  $0 keycloak-prod.example.com grafana-prod.example.com api-prod.example.com

Environment Variables:
  ENVOY_GATEWAY_NAMESPACE   Namespace where Envoy Gateway is installed (default: envoy-gateway-system)
  GATEWAY_NAME              Name of the Gateway resource (default: eg-gateway)
  GATEWAY_CERT_NAME         Name of the Certificate resource (default: gateway-tls-cert)
  GATEWAY_CERT_SECRET       Name of the TLS Secret (default: gateway-tls)

EOF
  exit 1
}

# ── Main ─────────────────────────────────────────────────────────────────────
main() {
  # Parse arguments
  if [[ $# -eq 0 ]]; then
    usage
  fi

  local hostnames=()
  for arg in "$@"; do
    if [[ "$arg" == "-h" ]] || [[ "$arg" == "--help" ]]; then
      usage
    fi

    if validate_hostname "$arg"; then
      hostnames+=("$arg")
    else
      error_exit "Invalid hostname: $arg"
    fi
  done

  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  Add Custom DNS to Envoy Gateway"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
  log_info "Gateway: $GATEWAY_NAME (namespace: $NAMESPACE)"
  log_info "Certificate: $CERT_NAME"
  log_info "Hostnames to add: ${hostnames[*]}"
  echo ""

  # Preflight checks
  log_info "Running preflight checks..."
  check_prerequisites
  log_success "Preflight checks passed"
  echo ""

  # Step 1: Add hostnames to certificate
  log_info "Step 1/4: Adding hostnames to certificate..."
  local cert_modified=false
  for hostname in "${hostnames[@]}"; do
    if ! hostname_in_cert "$hostname"; then
      add_to_certificate "$hostname"
      cert_modified=true
    else
      log_warning "Hostname '$hostname' already in certificate"
    fi
  done

  # Step 2: Wait for certificate
  if [[ "$cert_modified" == "true" ]]; then
    echo ""
    log_info "Step 2/4: Waiting for certificate to be reissued..."
    if ! wait_for_certificate; then
      error_exit "Certificate failed to become ready. Check with: kubectl describe certificate $CERT_NAME -n $NAMESPACE"
    fi
  else
    echo ""
    log_info "Step 2/4: Certificate unchanged, skipping wait"
  fi

  # Step 3: Add gateway listeners
  echo ""
  log_info "Step 3/4: Adding gateway listeners..."
  for hostname in "${hostnames[@]}"; do
    add_gateway_listener "$hostname"
  done

  # Step 4: Verify configuration
  echo ""
  log_info "Step 4/4: Verifying configuration..."
  sleep 2  # Brief pause for gateway to sync
  verify_configuration "${hostnames[@]}"

  # Show test commands
  show_test_commands "${hostnames[@]}"

  echo ""
  log_success "Configuration complete!"
}

main "$@"
