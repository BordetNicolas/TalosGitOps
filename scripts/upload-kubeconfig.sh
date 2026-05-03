#!/usr/bin/env bash
# Push the freshly generated kubeconfig to the configured MinIO bucket.
# Idempotent: re-running overwrites the object with the latest content.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "${SCRIPT_DIR}/lib.sh"

require_cmd mc

ensure_env \
  AWS_ACCESS_KEY_ID \
  AWS_SECRET_ACCESS_KEY \
  MINIO_ENDPOINT \
  MINIO_KUBECONFIG_BUCKET \
  MINIO_KUBECONFIG_KEY

[[ -f "${KUBECONFIG_PATH}" ]] ||
  die "kubeconfig not found at ${KUBECONFIG_PATH}; run 'make talos-bootstrap' first"

ALIAS="talos-minio-$$"

cleanup() { mc alias remove "${ALIAS}" >/dev/null 2>&1 || true; }
trap cleanup EXIT

log "configuring mc alias against ${MINIO_ENDPOINT}"
mc alias set --quiet "${ALIAS}" \
  "${MINIO_ENDPOINT}" \
  "${AWS_ACCESS_KEY_ID}" \
  "${AWS_SECRET_ACCESS_KEY}"

log "ensuring bucket ${MINIO_KUBECONFIG_BUCKET} exists"
mc mb --ignore-existing "${ALIAS}/${MINIO_KUBECONFIG_BUCKET}" >/dev/null

DEST="${ALIAS}/${MINIO_KUBECONFIG_BUCKET}/${MINIO_KUBECONFIG_KEY}"
log "uploading kubeconfig to ${DEST}"
mc cp --quiet "${KUBECONFIG_PATH}" "${DEST}"

log "done."
log "S3 path:     s3://${MINIO_KUBECONFIG_BUCKET}/${MINIO_KUBECONFIG_KEY}"
log "MinIO URL:   ${MINIO_ENDPOINT%/}/${MINIO_KUBECONFIG_BUCKET}/${MINIO_KUBECONFIG_KEY}"

if mc share download --expire 24h "${DEST}" 2>/dev/null | grep -E '^Share' || true; then
  :
fi
