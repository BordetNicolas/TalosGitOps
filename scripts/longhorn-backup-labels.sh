#!/usr/bin/env bash
# Attach PVCs to the Longhorn "backup" recurring job group (gitops/longhorn/recurringjobs.yaml).
#
# These PVCs are created by StatefulSet volumeClaimTemplates (immutable) and are not
# tracked by ArgoCD, so the labels are applied here. Idempotent; re-run after a PVC
# is recreated (new cluster, restore, resize by recreation).
#
# recurring-job.longhorn.io/source=enabled makes Longhorn sync the PVC's recurring job
# labels to the volume, replacing the volume's own: the "default" group label is kept
# so snapshot-cleanup / filesystem-trim still apply.
#
# Override the list in cluster.env: LONGHORN_BACKUP_PVCS="ns/pvc ns/pvc"
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "${SCRIPT_DIR}/lib.sh"

require_cmd kubectl

LONGHORN_BACKUP_PVCS="${LONGHORN_BACKUP_PVCS:-monitoring/storage-loki-0 airflow/data-airflow-postgresql-0}"

if [[ -f "${KUBECONFIG_PATH}" ]]; then
  export KUBECONFIG="${KUBECONFIG_PATH}"
else
  ctx="$(kubectl config current-context 2>/dev/null || true)"
  [[ "${ctx}" == *"${CLUSTER}"* ]] \
    || die "kubeconfig not found (${KUBECONFIG_PATH}) and current context '${ctx}' does not match ${CLUSTER}"
  log "using current kubectl context ${ctx}"
fi

for item in ${LONGHORN_BACKUP_PVCS}; do
  ns="${item%%/*}" pvc="${item#*/}"
  if ! kubectl -n "${ns}" get pvc "${pvc}" &>/dev/null; then
    warn "PVC ${ns}/${pvc} not found — skipped"
    continue
  fi
  kubectl -n "${ns}" label pvc "${pvc}" --overwrite \
    recurring-job.longhorn.io/source=enabled \
    recurring-job-group.longhorn.io/backup=enabled \
    recurring-job-group.longhorn.io/default=enabled
done

log "done — check: kubectl -n longhorn-system get volumes.longhorn.io -L recurring-job-group.longhorn.io/backup"
