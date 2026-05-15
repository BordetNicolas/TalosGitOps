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
  ARGOCD_INGRESS_HOST \
  GRAFANA_INGRESS_HOST \
  METALLB_POOL_RANGE

SRC="${GITOPS_TEMPLATES_DIR}"
DST="${GITOPS_DIR}"

substitute() {
  local src="$1" dst="$2"
  sed \
    -e "s|__ARGOCD_GIT_REPO__|${ARGOCD_GIT_REPO}|g" \
    -e "s|__ARGOCD_GIT_REVISION__|${ARGOCD_GIT_REVISION}|g" \
    -e "s|__ARGOCD_INGRESS_HOST__|${ARGOCD_INGRESS_HOST}|g" \
    -e "s|__GRAFANA_INGRESS_HOST__|${GRAFANA_INGRESS_HOST}|g" \
    -e "s|__METALLB_POOL_RANGE__|${METALLB_POOL_RANGE}|g" \
    -e "s|__CLOUDFLARE_DOMAIN__|${CLOUDFLARE_DOMAIN:-__CLOUDFLARE_DOMAIN__}|g" \
    -e "s|__UNIFI_DOMAIN__|${UNIFI_DOMAIN:-__UNIFI_DOMAIN__}|g" \
    -e "s|__ACME_EMAIL__|${ACME_EMAIL:-__ACME_EMAIL__}|g" \
    -e "s|__DOPPLER_PROJECT__|${DOPPLER_PROJECT:-__DOPPLER_PROJECT__}|g" \
    -e "s|__DOPPLER_CONFIG__|${DOPPLER_CONFIG:-__DOPPLER_CONFIG__}|g" \
    -e "s|__UNIFI_SKIP_TLS_VERIFY__|${UNIFI_SKIP_TLS_VERIFY:-true}|g" \
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
render_dir cert-manager
render_dir doppler
render_dir observability

log "done — clusters/${CLUSTER}/gitops/ is ready."
log "Doppler: set DOPPLER_PROJECT/CONFIG in cluster.env, then: make CLUSTER=${CLUSTER} apply-doppler-token"
log "  git diff -- clusters/${CLUSTER}/gitops/"
log "  git add clusters/${CLUSTER}/gitops/ && git commit && git push"
