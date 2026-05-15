#!/usr/bin/env bash
# Apply Doppler service token Secret (Free plan — not committed to Git).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "${SCRIPT_DIR}/lib.sh"

[[ -n "${DOPPLER_SERVICE_TOKEN:-}" ]] || die "DOPPLER_SERVICE_TOKEN is not set in cluster.env"

kubeconfig="${CLUSTER_DIR}/kubeconfig"
[[ -f "$kubeconfig" ]] || die "kubeconfig not found: ${kubeconfig}"

src="${GITOPS_TEMPLATES_DIR}/doppler/doppler-service-token-secret.yaml"
out="${CLUSTER_DIR}/.secrets-rendered/doppler-service-token-secret.yaml"
mkdir -p "$(dirname "$out")"
sed "s|__DOPPLER_SERVICE_TOKEN__|${DOPPLER_SERVICE_TOKEN}|g" "$src" > "$out"

export KUBECONFIG="$kubeconfig"
kubectl apply -f "$out"

log "Doppler service token Secret applied (clusters/${CLUSTER}/.secrets-rendered/ — gitignored)."
