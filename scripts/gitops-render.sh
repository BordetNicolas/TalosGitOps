#!/usr/bin/env bash
# Render the GitOps tree by substituting placeholders with the values from
# the .env file.
#
# Why: the App-of-Apps points ArgoCD at this repo, so any child Application
# whose `spec.source.repoURL` references the user's Git URL must have it
# committed (ArgoCD reads from Git, not from a local kubectl apply). This
# script substitutes the placeholders in place; the operator then commits
# and pushes the result before running `make up`.
#
# Placeholders handled:
#   __ARGOCD_GIT_REPO__       (from $ARGOCD_GIT_REPO)
#   __ARGOCD_GIT_REVISION__   (from $ARGOCD_GIT_REVISION)
#   __ARGOCD_GIT_PATH__       (from $ARGOCD_GIT_PATH)
#   __ARGOCD_INGRESS_HOST__   (from $ARGOCD_INGRESS_HOST)
#   __METALLB_POOL_RANGE__    (from $METALLB_POOL_START - $METALLB_POOL_END
#                              if set, otherwise left untouched)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "${SCRIPT_DIR}/lib.sh"

ensure_env \
  ARGOCD_GIT_REPO \
  ARGOCD_GIT_REVISION \
  ARGOCD_GIT_PATH \
  ARGOCD_INGRESS_HOST

substitute() {
  local file="$1"
  sed -i \
    -e "s#__ARGOCD_GIT_REPO__#${ARGOCD_GIT_REPO}#g" \
    -e "s#__ARGOCD_GIT_REVISION__#${ARGOCD_GIT_REVISION}#g" \
    -e "s#__ARGOCD_GIT_PATH__#${ARGOCD_GIT_PATH}#g" \
    -e "s#__ARGOCD_INGRESS_HOST__#${ARGOCD_INGRESS_HOST}#g" \
    "$file"
}

mapfile -t FILES < <(grep -rlE '__(ARGOCD_GIT_REPO|ARGOCD_GIT_REVISION|ARGOCD_GIT_PATH|ARGOCD_INGRESS_HOST)__' "${GITOPS_DIR}" 2>/dev/null || true)

if [[ ${#FILES[@]} -eq 0 ]]; then
  log "no placeholders found in ${GITOPS_DIR}; gitops/ is already rendered."
  exit 0
fi

for f in "${FILES[@]}"; do
  log "rendering ${f}"
  substitute "$f"
done

log "done. Review the diff and commit the changes:"
log "  git diff -- gitops/"
log "  git add gitops/ && git commit -m 'gitops: render placeholders for $(echo "${ARGOCD_GIT_REPO}" | sed 's#.*/##')'"
log "  git push"
