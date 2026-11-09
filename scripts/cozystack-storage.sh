#!/usr/bin/env bash
# Create the LINSTOR storage pool "data" (ZFS) on every worker's raw data disk.
# Idempotent. Mirrors the Cozystack install guide ("Create Storage Pools"); the StorageClasses
# that use this pool are managed by ArgoCD (gitops-cozystack/cozystack-storage).
#
# Env: LINSTOR_DEVICE (default /dev/sdb = scsi1, the extra disk created by OpenTofu)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "${SCRIPT_DIR}/lib.sh"

require_cmd kubectl
export KUBECONFIG="${KUBECONFIG_PATH}"
DEVICE="${LINSTOR_DEVICE:-/dev/sdb}"
POOL="data"

# ASCII tables: the default UTF-8 box drawing (│) would not match the "\|" greps below.
linstor() { kubectl exec -n cozy-linstor deploy/linstor-controller -- linstor --no-utf8 --no-color "$@"; }

log "waiting for the LINSTOR controller (platform install, timeout 45m)"
for _ in $(seq 1 270); do
  kubectl -n cozy-linstor get deploy/linstor-controller >/dev/null 2>&1 && break
  sleep 10
done
kubectl -n cozy-linstor rollout status deploy/linstor-controller --timeout=15m

mapfile -t WORKERS < <(kubectl get nodes -l '!node-role.kubernetes.io/control-plane' \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
((${#WORKERS[@]})) || die "no worker node found"
log "workers: ${WORKERS[*]}"

log "waiting for the LINSTOR satellites of the workers to be Online (timeout 15m)"
for _ in $(seq 1 90); do
  out="$(linstor node list 2>/dev/null || true)"
  missing=0
  for n in "${WORKERS[@]}"; do
    grep -E "\| ${n} +\|.*Online" <<<"${out}" >/dev/null || missing=$((missing + 1))
  done
  [[ "${missing}" -eq 0 ]] && break
  sleep 10
done
[[ "${missing}" -eq 0 ]] || die "${missing} worker satellite(s) not Online: $(linstor node list)"

for n in "${WORKERS[@]}"; do
  if linstor storage-pool list -n "${n}" -s "${POOL}" 2>/dev/null | grep -qE "\| ${POOL} +\|"; then
    log "${n}: pool ${POOL} already exists"
  else
    log "${n}: creating ZFS pool ${POOL} on ${DEVICE}"
    linstor physical-storage create-device-pool zfs "${n}" "${DEVICE}" \
      --pool-name "${POOL}" --storage-pool "${POOL}"
  fi
  # Recommended by Cozystack: let DRBD, not ZFS, handle disk failures.
  # Satellite pods come from a DaemonSet (random suffix): look them up by label + node.
  sat="$(kubectl -n cozy-linstor get pods -l app.kubernetes.io/component=linstor-satellite \
    --field-selector "spec.nodeName=${n}" -o jsonpath='{.items[0].metadata.name}')"
  kubectl exec -n cozy-linstor "pod/${sat}" -- zpool set failmode=continue "${POOL}" ||
    warn "${n}: could not set failmode=continue on zpool ${POOL}"
done

linstor storage-pool list
