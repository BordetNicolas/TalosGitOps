#!/usr/bin/env bash
# Apply the runtime secrets Cozystack needs (never committed).
#   - cozy-cert-manager/cloudflare-api-token-secret : Cloudflare token for DNS-01 certificates
#     (publishing.certificates.dns01.cloudflare in the Platform Package).
#   - tenant-root/pve-exporter : Proxmox API token (role PVEAuditor) read by pve-exporter
#     (PVE_EXPORTER_USER, PVE_EXPORTER_TOKEN_NAME, PVE_EXPORTER_TOKEN_VALUE in cluster.env).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "${SCRIPT_DIR}/lib.sh"

require_cmd kubectl
export KUBECONFIG="${KUBECONFIG_PATH}"

apply_cloudflare_secret() {
  if [[ -z "${CLOUDFLARE_API_TOKEN:-}" ]]; then
    warn "CLOUDFLARE_API_TOKEN is empty in clusters/${CLUSTER}/cluster.env — skipping."
    warn "Certificates (letsencrypt-prod, DNS-01) will stay Pending until you set it and rerun: make CLUSTER=${CLUSTER} cozystack-secrets"
    return 0
  fi

  log "waiting for namespace cozy-cert-manager (created by the platform install)"
  for _ in $(seq 1 180); do
    kubectl get ns cozy-cert-manager >/dev/null 2>&1 && break
    sleep 10
  done
  kubectl get ns cozy-cert-manager >/dev/null ||
    die "namespace cozy-cert-manager not found after 30 min — check 'kubectl get hr -A'"

  kubectl -n cozy-cert-manager create secret generic cloudflare-api-token-secret \
    --from-literal=api-token="${CLOUDFLARE_API_TOKEN}" \
    --dry-run=client -o yaml | kubectl apply -f -
  log "secret cozy-cert-manager/cloudflare-api-token-secret applied"
}

apply_pve_exporter_secret() {
  if [[ -z "${PVE_EXPORTER_USER:-}" || -z "${PVE_EXPORTER_TOKEN_NAME:-}" || -z "${PVE_EXPORTER_TOKEN_VALUE:-}" ]]; then
    warn "PVE_EXPORTER_USER / PVE_EXPORTER_TOKEN_NAME / PVE_EXPORTER_TOKEN_VALUE incomplete in clusters/${CLUSTER}/cluster.env — skipping."
    warn "pve-exporter will stay in CreateContainerConfigError until you set them and rerun: make CLUSTER=${CLUSTER} cozystack-secrets"
    return 0
  fi

  kubectl get ns tenant-root >/dev/null || die "namespace tenant-root not found — is Cozystack installed?"
  kubectl -n tenant-root create secret generic pve-exporter \
    --from-literal=PVE_USER="${PVE_EXPORTER_USER}" \
    --from-literal=PVE_TOKEN_NAME="${PVE_EXPORTER_TOKEN_NAME}" \
    --from-literal=PVE_TOKEN_VALUE="${PVE_EXPORTER_TOKEN_VALUE}" \
    --dry-run=client -o yaml | kubectl apply -f -
  log "secret tenant-root/pve-exporter applied"
}

apply_cloudflare_secret
apply_pve_exporter_secret
