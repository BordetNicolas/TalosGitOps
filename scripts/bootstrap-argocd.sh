#!/usr/bin/env bash
# Bootstrap ArgoCD on a freshly bootstrapped Talos cluster, then hand control
# to the GitOps App-of-Apps.  Cilium is already running as a Talos inline
# manifest (applied during talos-config), so this script only needs ArgoCD.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "${SCRIPT_DIR}/lib.sh"

require_cmd helm
require_cmd kubectl

ensure_env \
  ARGOCD_GIT_REPO \
  ARGOCD_GIT_REVISION \
  ARGOCD_INGRESS_HOST

ARGOCD_CHART_VERSION="${ARGOCD_CHART_VERSION:-8.3.0}"
export KUBECONFIG="${KUBECONFIG_PATH}"

[[ -f "${GITOPS_DIR}/bootstrap/root-app.yaml" ]] ||
  die "gitops not rendered for cluster ${CLUSTER}. Run 'make CLUSTER=${CLUSTER} gitops-render' first."

# ---------------------------------------------------------------------------
# ArgoCD
# ---------------------------------------------------------------------------
helm repo list 2>/dev/null | awk '{print $1}' | grep -qx "argo" ||
  helm repo add argo https://argoproj.github.io/argo-helm
helm repo update argo >/dev/null

log "installing/upgrading ArgoCD ${ARGOCD_CHART_VERSION}"
kubectl get ns argocd >/dev/null 2>&1 || kubectl create ns argocd

helm upgrade --install argocd argo/argo-cd \
  --namespace argocd \
  --version "${ARGOCD_CHART_VERSION}" \
  --values "${BOOTSTRAP_DIR}/argocd-values.yaml" \
  --wait \
  --timeout 10m

log "waiting for ArgoCD server to be Ready"
kubectl -n argocd rollout status deploy/argocd-server --timeout=10m

# ---------------------------------------------------------------------------
# App-of-Apps root — ArgoCD takes over all remaining components.
# Files are pre-rendered by `make gitops-render`; no envsubst needed.
# ---------------------------------------------------------------------------
log "applying root App-of-Apps"
kubectl apply -f "${GITOPS_DIR}/projects/platform.yaml"
kubectl apply -f "${GITOPS_DIR}/bootstrap/root-app.yaml"

log "GitOps bootstrap complete."
log ""
log "ArgoCD UI:        https://${ARGOCD_INGRESS_HOST}"
log "Initial password: kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
log ""
log "ArgoCD will sync everything from ${ARGOCD_GIT_REPO}@${ARGOCD_GIT_REVISION}."
