#!/usr/bin/env bash
# Create the MinIO buckets required by OpenTofu (state) and kubeconfig upload
# if they do not exist yet. OpenTofu's S3 backend returns NoSuchBucket when the
# bucket is missing — credentials can still be valid.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "${SCRIPT_DIR}/lib.sh"

require_cmd mc

ensure_env \
  AWS_ACCESS_KEY_ID \
  AWS_SECRET_ACCESS_KEY \
  MINIO_ENDPOINT \
  MINIO_STATE_BUCKET \
  MINIO_KUBECONFIG_BUCKET

ALIAS="talos-minio-buckets-$$"

cleanup() { mc alias remove "${ALIAS}" >/dev/null 2>&1 || true; }
trap cleanup EXIT

log "configuring mc alias against ${MINIO_ENDPOINT}"
mc alias set --quiet "${ALIAS}" \
  "${MINIO_ENDPOINT}" \
  "${AWS_ACCESS_KEY_ID}" \
  "${AWS_SECRET_ACCESS_KEY}"

for bucket in "${MINIO_STATE_BUCKET}" "${MINIO_KUBECONFIG_BUCKET}"; do
  log "ensuring bucket exists: ${bucket}"
  mc mb --ignore-existing "${ALIAS}/${bucket}" >/dev/null
done

log "MinIO buckets ready."
