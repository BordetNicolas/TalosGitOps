#!/usr/bin/env bash
# Cozystack bootstrap (PLATFORM_FLAVOR=cozystack): runs after `talosctl bootstrap`, before ArgoCD.
#
# Talos is installed with cni=none, so no pod can run until Cozystack installs its CNI
# (Cilium + Kube-OVN). ArgoCD therefore cannot be the first installer: we install the
# operator and apply the Platform Package by hand, wait for the nodes to become Ready,
# then bootstrap-argocd.sh installs ArgoCD, which adopts both from Git.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "${SCRIPT_DIR}/lib.sh"

[[ "${PLATFORM_FLAVOR}" == "cozystack" ]] || die "PLATFORM_FLAVOR is not cozystack for cluster ${CLUSTER}"
require_cmd helm
require_cmd kubectl
ensure_env COZYSTACK_VERSION

export KUBECONFIG="${KUBECONFIG_PATH}"
PACKAGE="${GITOPS_DIR}/cozystack-platform/package.yaml"
[[ -f "${PACKAGE}" ]] ||
  die "gitops not rendered for cluster ${CLUSTER}. Run 'make CLUSTER=${CLUSTER} gitops-render' first."

log "installing cozy-installer ${COZYSTACK_VERSION} (operator, CRDs)"
helm upgrade --install cozystack oci://ghcr.io/cozystack/cozystack/cozy-installer \
  --version "${COZYSTACK_VERSION}" \
  --namespace cozy-system \
  --create-namespace

log "waiting for the Cozystack operator"
for _ in $(seq 1 60); do
  kubectl -n cozy-system get deploy/cozystack-operator >/dev/null 2>&1 && break
  sleep 5
done
kubectl -n cozy-system rollout status deploy/cozystack-operator --timeout=10m

log "waiting for the PackageSource created by the installer"
for _ in $(seq 1 60); do
  kubectl get packagesource cozystack.cozystack-platform >/dev/null 2>&1 && break
  sleep 5
done
kubectl get packagesource cozystack.cozystack-platform >/dev/null ||
  die "PackageSource cozystack.cozystack-platform not found (kubectl get packagesource)"

log "applying the Platform Package ${PACKAGE}"
kubectl apply -f "${PACKAGE}"

log "waiting for the nodes to become Ready (Cilium + Kube-OVN come from the Package, timeout 30m)"
kubectl wait --for=condition=Ready nodes --all --timeout=30m

log "Cozystack CNI is up. Platform HelmReleases keep reconciling in the background:"
log "  KUBECONFIG=${KUBECONFIG_PATH} kubectl get hr -A"
