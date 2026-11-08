#!/usr/bin/env bash
# Apply the runtime secrets Cozystack needs (never committed).
#   - cozy-cert-manager/cloudflare-api-token-secret : Cloudflare token for DNS-01 certificates
#     (publishing.certificates.dns01.cloudflare in the Platform Package).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "${SCRIPT_DIR}/lib.sh"

require_cmd kubectl
export KUBECONFIG="${KUBECONFIG_PATH}"

if [[ -z "${CLOUDFLARE_API_TOKEN:-}" ]]; then
  warn "CLOUDFLARE_API_TOKEN is empty in clusters/${CLUSTER}/cluster.env — skipping."
  warn "Certificates (letsencrypt-prod, DNS-01) will stay Pending until you set it and rerun: make CLUSTER=${CLUSTER} cozystack-secrets"
  exit 0
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
