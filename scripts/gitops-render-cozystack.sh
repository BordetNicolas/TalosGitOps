#!/usr/bin/env bash
# Render gitops-cozystack/ templates into clusters/${CLUSTER}/gitops/ (PLATFORM_FLAVOR=cozystack).
# Called by gitops-render.sh. No secret is rendered: the Cloudflare token is applied
# at runtime by apply-cozystack-secrets.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "${SCRIPT_DIR}/lib.sh"

ensure_env \
  ARGOCD_GIT_REPO \
  ARGOCD_GIT_REVISION \
  COZYSTACK_VERSION \
  COZY_ROOT_HOST \
  COZY_EXTERNAL_IP_RANGE

[[ "${COZY_EXTERNAL_IP_RANGE}" =~ ^[0-9.]+-[0-9.]+$ ]] ||
  die "COZY_EXTERNAL_IP_RANGE must look like 192.168.20.60-192.168.20.79 (got: ${COZY_EXTERNAL_IP_RANGE})"

ARGOCD_CHART_VERSION="${ARGOCD_CHART_VERSION:-8.3.0}"
ARGOCD_INGRESS_HOST="${ARGOCD_INGRESS_HOST:-argocd.${COZY_ROOT_HOST}}"

log "cozystack ${COZYSTACK_VERSION}, root host ${COZY_ROOT_HOST}, argocd ${ARGOCD_INGRESS_HOST}"
log "git source: ${ARGOCD_GIT_REPO}@${ARGOCD_GIT_REVISION}"
log "metallb pool: ${COZY_EXTERNAL_IP_RANGE}"

SRC="${GITOPS_TEMPLATES_DIR}"
DST="${GITOPS_DIR}"

substitute() {
  local src="$1" dst="$2"
  sed \
    -e "s|__ARGOCD_GIT_REPO__|${ARGOCD_GIT_REPO}|g" \
    -e "s|__ARGOCD_GIT_REVISION__|${ARGOCD_GIT_REVISION}|g" \
    -e "s|__ARGOCD_CHART_VERSION__|${ARGOCD_CHART_VERSION}|g" \
    -e "s|__ARGOCD_INGRESS_HOST__|${ARGOCD_INGRESS_HOST}|g" \
    -e "s|__COZYSTACK_VERSION__|${COZYSTACK_VERSION}|g" \
    -e "s|__COZY_ROOT_HOST__|${COZY_ROOT_HOST}|g" \
    -e "s|__COZY_EXTERNAL_IP_RANGE__|${COZY_EXTERNAL_IP_RANGE}|g" \
    -e "s|__CLUSTER__|${CLUSTER}|g" \
    -e "s|path: gitops/|path: clusters/${CLUSTER}/gitops/|g" \
    "$src" > "$dst"
  if grep -nE '__[A-Z0-9_]+__' "$dst" >/dev/null; then
    die "unresolved placeholder in ${dst}: $(grep -noE '__[A-Z0-9_]+__' "$dst" | head -3 | tr '\n' ' ')"
  fi
}

render_dir() {
  local rel="$1"
  local src_dir="${SRC}/${rel}" dst_dir="${DST}/${rel}"
  [[ -d "$src_dir" ]] || return 0
  mkdir -p "$dst_dir"
  local f name
  for f in "${src_dir}"/*.yaml; do
    [[ -f "$f" ]] || continue
    name="$(basename "$f")"
    substitute "$f" "${dst_dir}/${name}"
    log "rendered clusters/${CLUSTER}/gitops/${rel}/${name}"
  done
}

# Drop previously rendered files so a template removed from the repo disappears here too.
rm -rf "${DST}"

for d in apps bootstrap projects argocd cozystack-platform cozystack-metallb cozystack-storage cozystack-tenant tenants/lab workflows-cluster airflow-secrets airflow; do
  render_dir "$d"
done

log "done — clusters/${CLUSTER}/gitops/ is ready (ArgoCD reads it from branch ${ARGOCD_GIT_REVISION})."
log "  git add clusters/${CLUSTER}/gitops/ && git commit && git push"
