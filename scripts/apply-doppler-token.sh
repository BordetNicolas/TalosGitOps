#!/usr/bin/env bash
# Apply Doppler service token Secret (Free plan — not committed to Git).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "${SCRIPT_DIR}/lib.sh"

require_cmd kubectl

kubeconfig="${CLUSTER_DIR}/kubeconfig"
[[ -f "$kubeconfig" ]] || die "kubeconfig not found: ${kubeconfig}"
export KUBECONFIG="$kubeconfig"

if [[ -z "${DOPPLER_SERVICE_TOKEN:-}" ]]; then
  warn "DOPPLER_SERVICE_TOKEN not set in cluster.env — skipping Doppler token (no Doppler-managed secrets)."
  exit 0
fi

wait_for_namespace() {
  local ns="$1" timeout="${2:-600}"
  log "waiting for namespace ${ns} (ArgoCD sync)..."
  local elapsed=0
  while (( elapsed < timeout )); do
    if kubectl get ns "${ns}" &>/dev/null; then
      return 0
    fi
    sleep 5
    elapsed=$(( elapsed + 5 ))
  done
  die "timeout (${timeout}s) waiting for namespace ${ns} — check ArgoCD apps platform-namespaces / doppler-operator"
}

wait_for_doppler_operator() {
  local deploy="doppler-operator-controller-manager"
  kubectl -n doppler-operator-system get deploy "${deploy}" &>/dev/null || return 0
  log "waiting for Doppler operator..."
  kubectl -n doppler-operator-system rollout status "deploy/${deploy}" --timeout=5m
}

wait_for_doppler_sync() {
  local cr="external-dns-cloudflare-token"
  log "waiting for DopplerSecret ${cr} to sync..."
  local elapsed=0
  while (( elapsed < 180 )); do
    if ! kubectl -n doppler-operator-system get dopplersecret "${cr}" &>/dev/null; then
      sleep 5
      elapsed=$(( elapsed + 5 ))
      continue
    fi
    local status
    status="$(kubectl -n doppler-operator-system get dopplersecret "${cr}" \
      -o jsonpath='{.status.conditions[?(@.type=="secrets.doppler.com/SecretSyncReady")].status}' 2>/dev/null || true)"
    if [[ "${status}" == "True" ]]; then
      log "Doppler secrets synced"
      return 0
    fi
    sleep 5
    elapsed=$(( elapsed + 5 ))
  done
  warn "Doppler sync not confirmed within 3m — operator will retry; check: kubectl get dopplersecret -A"
}

wait_for_namespace doppler-operator-system

src="${GITOPS_TEMPLATES_DIR}/doppler/doppler-service-token-secret.yaml"
out="${CLUSTER_DIR}/.secrets-rendered/doppler-service-token-secret.yaml"
mkdir -p "$(dirname "$out")"
sed "s|__DOPPLER_SERVICE_TOKEN__|${DOPPLER_SERVICE_TOKEN}|g" "$src" > "$out"
kubectl apply -f "$out"

log "Doppler service token applied (clusters/${CLUSTER}/.secrets-rendered/ — gitignored)."

wait_for_doppler_operator
wait_for_namespace external-dns 120 || true
wait_for_doppler_sync
