#!/usr/bin/env bash
# Apply the runtime secrets of the tenant cluster "workflows" (never committed).
#   - workflows-argo/minio-artifacts : S3 credentials of the Argo Workflows artifact repository
#     (see artifact-repositories ConfigMap in the WorkflowsArgo repo: bucket argo-workflows).
# Reads MINIO_ARTIFACTS_ACCESS_KEY / MINIO_ARTIFACTS_SECRET_KEY from clusters/<cluster>/cluster.env.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "${SCRIPT_DIR}/lib.sh"

require_cmd kubectl

K8S_NAME="${1:-workflows}"
TENANT_NS="${2:-tenant-lab}"
TARGET_NS="workflows-argo"

if [[ -z "${MINIO_ARTIFACTS_ACCESS_KEY:-}" || -z "${MINIO_ARTIFACTS_SECRET_KEY:-}" ]]; then
  warn "MINIO_ARTIFACTS_ACCESS_KEY / MINIO_ARTIFACTS_SECRET_KEY are empty in clusters/${CLUSTER}/cluster.env — skipping."
  warn "Workflows using the artifact repository will fail until you set them and rerun: make CLUSTER=${CLUSTER} cozystack-workflows-secrets"
  exit 0
fi

tenant_kc="$(mktemp)"
trap 'rm -f "${tenant_kc}"' EXIT
KUBECONFIG="${KUBECONFIG_PATH}" kubectl -n "${TENANT_NS}" get secret "kubernetes-${K8S_NAME}-admin-kubeconfig" \
  -o jsonpath='{.data.admin\.conf}' | base64 -d > "${tenant_kc}"
[[ -s "${tenant_kc}" ]] || die "kubeconfig of cluster ${K8S_NAME} not found in ${TENANT_NS}"
export KUBECONFIG="${tenant_kc}"

kubectl get ns "${TARGET_NS}" >/dev/null 2>&1 || kubectl create ns "${TARGET_NS}"
kubectl -n "${TARGET_NS}" create secret generic minio-artifacts \
  --from-literal=accessKey="${MINIO_ARTIFACTS_ACCESS_KEY}" \
  --from-literal=secretKey="${MINIO_ARTIFACTS_SECRET_KEY}" \
  --dry-run=client -o yaml | kubectl apply -f -
log "secret ${TARGET_NS}/minio-artifacts applied in cluster ${K8S_NAME}"
