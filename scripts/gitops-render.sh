#!/usr/bin/env bash
# Render the GitOps templates in gitops/ into clusters/${CLUSTER}/gitops/.
#
# Source:  gitops/          — templates with __PLACEHOLDER__ markers
# Output:  clusters/${CLUSTER}/gitops/ — rendered, committed, read by ArgoCD
#
# Runtime secrets (API tokens) are synced by Doppler — see gitops/doppler/.
# Only non-secret values (ACME email, Doppler project/config/identity IDs) come from cluster.env.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "${SCRIPT_DIR}/lib.sh"

ensure_env \
  ARGOCD_GIT_REPO \
  ARGOCD_GIT_REVISION \
  APPS_GIT_REPO \
  APPS_GIT_REVISION \
  METALLB_POOL_RANGE

export_platform_ingress_hosts
ensure_env ARGOCD_INGRESS_HOST LONGHORN_INGRESS_HOST GRAFANA_INGRESS_HOST ARGOWF_INGRESS_HOST

if [[ -n "${UNIFI_HOST:-}" ]]; then
  export UNIFI_HOST="$(normalize_unifi_host)"
fi

log "ingress hosts (env=$(platform_env)): argocd=${ARGOCD_INGRESS_HOST} longhorn=${LONGHORN_INGRESS_HOST} grafana=${GRAFANA_INGRESS_HOST} argowf=${ARGOWF_INGRESS_HOST}"
[[ -n "${UNIFI_HOST:-}" ]] && log "unifi API: ${UNIFI_HOST}"

# Shared ingress VIP = first address of MetalLB pool (ingress-nginx LoadBalancer).
METALLB_VIP="${METALLB_POOL_RANGE%%-*}"
export METALLB_VIP
log "metallb ingress VIP: ${METALLB_VIP}"

# Prefer explicit override, else OpenTofu kubernetes_api_host (same as Cilium bootstrap).
if [[ -z "${KUBERNETES_API_HOST:-}" ]]; then
  KUBERNETES_API_HOST="$(tofu_var 'var.cluster.kubernetes_api_host' | tr -d '"' || true)"
  if [[ -z "${KUBERNETES_API_HOST}" || "${KUBERNETES_API_HOST}" == "null" ]]; then
    KUBERNETES_API_HOST="$(tofu_output_raw kubernetes_api_host || true)"
  fi
fi
if [[ -z "${KUBERNETES_API_HOST}" || "${KUBERNETES_API_HOST}" == "null" ]]; then
  die "KUBERNETES_API_HOST unset and OpenTofu kubernetes_api_host unavailable. Set cluster.kubernetes_api_host in terraform.tfvars or export KUBERNETES_API_HOST."
fi
export KUBERNETES_API_HOST
log "kubernetes API host: ${KUBERNETES_API_HOST}"

SRC="${GITOPS_TEMPLATES_DIR}"
DST="${GITOPS_DIR}"

substitute() {
  local src="$1" dst="$2"
  sed \
    -e "s|__ARGOCD_GIT_REPO__|${ARGOCD_GIT_REPO}|g" \
    -e "s|__ARGOCD_GIT_REVISION__|${ARGOCD_GIT_REVISION}|g" \
    -e "s|__APPS_GIT_REPO__|${APPS_GIT_REPO}|g" \
    -e "s|__APPS_GIT_REVISION__|${APPS_GIT_REVISION}|g" \
    -e "s|__ARGOCD_INGRESS_HOST__|${ARGOCD_INGRESS_HOST}|g" \
    -e "s|__LONGHORN_INGRESS_HOST__|${LONGHORN_INGRESS_HOST}|g" \
    -e "s|__GRAFANA_INGRESS_HOST__|${GRAFANA_INGRESS_HOST}|g" \
    -e "s|__ARGOWF_INGRESS_HOST__|${ARGOWF_INGRESS_HOST}|g" \
    -e "s|__METALLB_VIP__|${METALLB_VIP}|g" \
    -e "s|__METALLB_POOL_RANGE__|${METALLB_POOL_RANGE}|g" \
    -e "s|__CLOUDFLARE_DOMAIN__|${CLOUDFLARE_DOMAIN:-__CLOUDFLARE_DOMAIN__}|g" \
    -e "s|__UNIFI_DOMAIN__|${UNIFI_DOMAIN:-__UNIFI_DOMAIN__}|g" \
    -e "s|__ACME_EMAIL__|${ACME_EMAIL:-__ACME_EMAIL__}|g" \
    -e "s|__DOPPLER_PROJECT__|${DOPPLER_PROJECT:-__DOPPLER_PROJECT__}|g" \
    -e "s|__DOPPLER_CONFIG__|${DOPPLER_CONFIG:-__DOPPLER_CONFIG__}|g" \
    -e "s|__UNIFI_SKIP_TLS_VERIFY__|${UNIFI_SKIP_TLS_VERIFY:-true}|g" \
    -e "s|__UNIFI_HOST__|${UNIFI_HOST:-https://unifi.local}|g" \
    -e "s|__KUBERNETES_API_HOST__|${KUBERNETES_API_HOST}|g" \
    -e "s|__CLUSTER__|${CLUSTER}|g" \
    -e "s|path: gitops/|path: clusters/${CLUSTER}/gitops/|g" \
    "$src" > "$dst"
}

render_dir() {
  local rel="$1"
  local src_dir="${SRC}/${rel}" dst_dir="${DST}/${rel}"
  [[ -d "$src_dir" ]] || return 0
  mkdir -p "$dst_dir"
  local f name
  for f in "${src_dir}"/*.yaml "${src_dir}"/*.yml; do
    [[ -f "$f" ]] || continue
    name="$(basename "$f")"
    if [[ "$name" == "doppler-service-token-secret.yaml" ]]; then
      continue
    fi
    substitute "$f" "${dst_dir}/${name}"
    log "rendered clusters/${CLUSTER}/gitops/${rel}/${name}"
  done
}

render_dir apps
render_dir bootstrap
render_dir namespaces
render_dir projects
render_dir metallb
render_dir argocd
render_dir longhorn
render_dir argo-workflows
render_dir cert-manager
render_dir external-dns
render_dir doppler
render_dir observability

log "done — clusters/${CLUSTER}/gitops/ is ready."
log "Doppler: set DOPPLER_PROJECT/CONFIG in cluster.env, then: make CLUSTER=${CLUSTER} apply-doppler-token"
log "  git diff -- clusters/${CLUSTER}/gitops/"
log "  git add clusters/${CLUSTER}/gitops/ && git commit && git push"
