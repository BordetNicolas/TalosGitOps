#!/usr/bin/env bash
# Register a Cozystack tenant Kubernetes cluster as an ArgoCD destination (never committed).
# Builds argocd/cluster-<name> from the tenant's "admin.svc" kubeconfig (internal service
# address, reachable from ArgoCD). Usage: cozystack-register-tenant-cluster.sh [cluster] [tenant-ns]
#   defaults: cluster=workflows, tenant namespace=tenant-lab -> ArgoCD cluster name "workflows-lab".

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "${SCRIPT_DIR}/lib.sh"

require_cmd kubectl
require_cmd jq
export KUBECONFIG="${KUBECONFIG_PATH}"

K8S_NAME="${1:-workflows}"
TENANT_NS="${2:-tenant-lab}"
ARGO_NAME="${K8S_NAME}-${TENANT_NS#tenant-}"
SECRET="kubernetes-${K8S_NAME}-admin-kubeconfig"

log "waiting for secret ${TENANT_NS}/${SECRET}"
for _ in $(seq 1 60); do
  kubectl -n "${TENANT_NS}" get secret "${SECRET}" >/dev/null 2>&1 && break
  sleep 10
done
kubectl -n "${TENANT_NS}" get secret "${SECRET}" >/dev/null ||
  die "secret ${TENANT_NS}/${SECRET} not found — check 'kubectl -n ${TENANT_NS} get kubernetes'"

kc="$(kubectl -n "${TENANT_NS}" get secret "${SECRET}" -o jsonpath='{.data.admin\.svc}' | base64 -d)"
field() { kubectl config view --kubeconfig <(printf '%s' "${kc}") --raw -o jsonpath="$1"; }

server="$(field '{.clusters[0].cluster.server}')"
ca="$(field '{.clusters[0].cluster.certificate-authority-data}')"
cert="$(field '{.users[0].user.client-certificate-data}')"
key="$(field '{.users[0].user.client-key-data}')"
[[ -n "${server}" && -n "${ca}" && -n "${cert}" && -n "${key}" ]] ||
  die "could not extract server/CA/client cert from ${SECRET} (admin.svc)"

config="$(jq -nc --arg ca "${ca}" --arg cert "${cert}" --arg key "${key}" \
  '{tlsClientConfig: {caData: $ca, certData: $cert, keyData: $key}}')"

kubectl -n argocd create secret generic "cluster-${ARGO_NAME}" \
  --from-literal=name="${ARGO_NAME}" \
  --from-literal=server="${server}" \
  --from-literal=project="lab" \
  --from-literal=config="${config}" \
  --dry-run=client -o yaml |
  kubectl label --local -f - argocd.argoproj.io/secret-type=cluster -o yaml |
  kubectl apply -f -
log "ArgoCD cluster '${ARGO_NAME}' registered (${server}), scoped to project lab"
