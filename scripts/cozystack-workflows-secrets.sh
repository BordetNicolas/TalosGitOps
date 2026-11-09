#!/usr/bin/env bash
# Wire the Argo Workflows artifact repository of the tenant cluster "workflows" to the Cozystack
# Bucket tenant-lab/workflows-artifacts (never committed: credentials and generated bucket name).
# Reads the COSI Secret <bucket>-<user> in the tenant namespace and applies, in workflows-argo:
#   - Secret    s3-artifacts          (accessKey / secretKey)
#   - ConfigMap artifact-repositories (key default-v1, referenced by the WorkflowTemplates)
# Usage: cozystack-workflows-secrets.sh [cluster] [tenant-ns] [bucket] [user]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "${SCRIPT_DIR}/lib.sh"

require_cmd kubectl
require_cmd jq

K8S_NAME="${1:-workflows}"
TENANT_NS="${2:-tenant-lab}"
BUCKET="${3:-workflows-artifacts}"
USER_NAME="${4:-argo}"
TARGET_NS="workflows-argo"
SECRET="${BUCKET}-${USER_NAME}"

log "waiting for secret ${TENANT_NS}/${SECRET} (COSI credentials)"
for _ in $(seq 1 60); do
  KUBECONFIG="${KUBECONFIG_PATH}" kubectl -n "${TENANT_NS}" get secret "${SECRET}" >/dev/null 2>&1 && break
  sleep 10
done
info="$(KUBECONFIG="${KUBECONFIG_PATH}" kubectl -n "${TENANT_NS}" get secret "${SECRET}" -o jsonpath='{.data.BucketInfo}' | base64 -d)" ||
  die "secret ${TENANT_NS}/${SECRET} not found — check 'kubectl -n ${TENANT_NS} get bucket,bucketclaim'"

endpoint="$(jq -r '.spec.secretS3.endpoint' <<<"${info}")"
bucket_name="$(jq -r '.spec.bucketName' <<<"${info}")"
access_key="$(jq -r '.spec.secretS3.accessKeyID' <<<"${info}")"
secret_key="$(jq -r '.spec.secretS3.accessSecretKey' <<<"${info}")"
[[ -n "${endpoint}" && -n "${bucket_name}" && -n "${access_key}" && -n "${secret_key}" && "${endpoint}" != null ]] ||
  die "incomplete BucketInfo in ${TENANT_NS}/${SECRET}"
host="${endpoint#*://}"
insecure=false
[[ "${endpoint}" == http://* ]] && insecure=true

tenant_kc="$(mktemp)"
trap 'rm -f "${tenant_kc}"' EXIT
KUBECONFIG="${KUBECONFIG_PATH}" kubectl -n "${TENANT_NS}" get secret "kubernetes-${K8S_NAME}-admin-kubeconfig" \
  -o jsonpath='{.data.admin\.conf}' | base64 -d > "${tenant_kc}"
[[ -s "${tenant_kc}" ]] || die "kubeconfig of cluster ${K8S_NAME} not found in ${TENANT_NS}"
export KUBECONFIG="${tenant_kc}"

kubectl get ns "${TARGET_NS}" >/dev/null 2>&1 || kubectl create ns "${TARGET_NS}"

kubectl -n "${TARGET_NS}" create secret generic s3-artifacts \
  --from-literal=accessKey="${access_key}" \
  --from-literal=secretKey="${secret_key}" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl apply -f - <<YAML
apiVersion: v1
kind: ConfigMap
metadata:
  name: artifact-repositories
  namespace: ${TARGET_NS}
  annotations:
    workflows.argoproj.io/default-artifact-repository: default-v1
data:
  default-v1: |
    s3:
      bucket: ${bucket_name}
      endpoint: ${host}
      region: us-east-1
      insecure: ${insecure}
      accessKeySecret:
        name: s3-artifacts
        key: accessKey
      secretKeySecret:
        name: s3-artifacts
        key: secretKey
YAML
log "artifact repository applied in cluster ${K8S_NAME}: s3://${bucket_name} @ ${host}"
