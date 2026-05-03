#!/usr/bin/env bash
# Bootstrap Cilium (mandatory CNI before any pod can run) and ArgoCD on a
# freshly bootstrapped Talos cluster, then hand control over to the GitOps
# App-of-Apps so ArgoCD adopts and maintains every component going forward.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "${SCRIPT_DIR}/lib.sh"

require_cmd helm
require_cmd kubectl
require_cmd envsubst
require_cmd tofu

ensure_env \
  ARGOCD_GIT_REPO \
  ARGOCD_GIT_REVISION \
  ARGOCD_GIT_PATH \
  ARGOCD_INGRESS_HOST

CILIUM_CHART_VERSION="${CILIUM_CHART_VERSION:-1.16.4}"
ARGOCD_CHART_VERSION="${ARGOCD_CHART_VERSION:-7.7.7}"

export KUBECONFIG="${KUBECONFIG_PATH}"

VIP="$(echo 'var.cluster.endpoint_vip' | tofu -chdir="${TOFU_DIR}" console | tr -d '"')"
[[ -n "$VIP" && "$VIP" != "null" ]] || die "could not read cluster.endpoint_vip from OpenTofu"

# ---------------------------------------------------------------------------
# 1) Cilium bootstrap (CNI). Without this no pod (including ArgoCD) starts.
# ---------------------------------------------------------------------------
helm_repo_add() {
  local name="$1" url="$2"
  helm repo list 2>/dev/null | awk '{print $1}' | grep -qx "$name" ||
    helm repo add "$name" "$url"
}

log "adding helm repos"
helm_repo_add cilium https://helm.cilium.io
helm_repo_add argo   https://argoproj.github.io/argo-helm
helm repo update >/dev/null

log "installing/upgrading Cilium ${CILIUM_CHART_VERSION}"
helm upgrade --install cilium cilium/cilium \
  --namespace kube-system \
  --version "${CILIUM_CHART_VERSION}" \
  --values "${BOOTSTRAP_DIR}/cilium-values.yaml" \
  --set k8sServiceHost="${VIP}" \
  --set k8sServicePort=6443 \
  --wait \
  --timeout 10m

log "waiting for Cilium DaemonSet to be Ready"
kubectl -n kube-system rollout status ds/cilium --timeout=10m

# ---------------------------------------------------------------------------
# 2) ArgoCD bootstrap. Once running, the GitOps root Application takes over.
# ---------------------------------------------------------------------------
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
# 3) Apply the App-of-Apps root. From this point ArgoCD reconciles every
#    component (Cilium adoption, ArgoCD self-managed, MetalLB, ingress, ...)
#    from gitops/apps/.
# ---------------------------------------------------------------------------
log "applying root App-of-Apps"
envsubst <"${GITOPS_DIR}/projects/platform.yaml" | kubectl apply -f -
envsubst <"${GITOPS_DIR}/bootstrap/root-app.yaml" | kubectl apply -f -

log "GitOps bootstrap complete."
log ""
log "ArgoCD UI:        https://${ARGOCD_INGRESS_HOST}"
log "Initial password: kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
log ""
log "ArgoCD will now sync everything from ${ARGOCD_GIT_REPO}@${ARGOCD_GIT_REVISION}/${ARGOCD_GIT_PATH}."
