#!/usr/bin/env bash
# Push the freshly generated kubeconfig to the configured MinIO bucket.
# Idempotent: re-running overwrites the object with the latest content.
#
# Uses MinIO Client (`mc`) by default. Set USE_AWS_CLI_FOR_KUBECONFIG=1 to force
# `aws s3 cp`. If `mc` fails, falls back to AWS CLI when available.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "${SCRIPT_DIR}/lib.sh"

ensure_env \
  AWS_ACCESS_KEY_ID \
  AWS_SECRET_ACCESS_KEY \
  MINIO_ENDPOINT \
  MINIO_KUBECONFIG_BUCKET \
  MINIO_KUBECONFIG_KEY

[[ -f "${KUBECONFIG_PATH}" ]] ||
  die "kubeconfig not found at ${KUBECONFIG_PATH}; run 'make talos-bootstrap' first"

# Subshell + trap : retire toujours l'alias mc en cas d'erreur.
upload_via_mc() (
  set -euo pipefail
  require_cmd mc
  local alias="talos-minio-$$"
  local insecure_flags=()
  if [[ "${MINIO_INSECURE:-}" == "true" || "${MINIO_INSECURE:-}" == "1" ]]; then
    insecure_flags=(--insecure)
  fi
  cleanup() { mc alias remove "${alias}" >/dev/null 2>&1 || true; }
  trap cleanup EXIT

  log "configuring mc alias against ${MINIO_ENDPOINT}"
  mc alias set "${insecure_flags[@]}" --quiet "${alias}" \
    "${MINIO_ENDPOINT}" \
    "${AWS_ACCESS_KEY_ID}" \
    "${AWS_SECRET_ACCESS_KEY}"

  log "ensuring bucket ${MINIO_KUBECONFIG_BUCKET} exists"
  mc mb "${insecure_flags[@]}" --ignore-existing "${alias}/${MINIO_KUBECONFIG_BUCKET}" >/dev/null

  local dest="${alias}/${MINIO_KUBECONFIG_BUCKET}/${MINIO_KUBECONFIG_KEY}"
  log "uploading kubeconfig to ${dest}"
  mc cp "${insecure_flags[@]}" "${KUBECONFIG_PATH}" "${dest}"

  log "verifying object on MinIO"
  mc stat "${insecure_flags[@]}" "${dest}"

  log "done (mc)."
  log "S3 path:     s3://${MINIO_KUBECONFIG_BUCKET}/${MINIO_KUBECONFIG_KEY}"
  log "MinIO URL:   ${MINIO_ENDPOINT%/}/${MINIO_KUBECONFIG_BUCKET}/${MINIO_KUBECONFIG_KEY}"
)

upload_via_aws_cli() {
  require_cmd aws
  export AWS_EC2_METADATA_DISABLED=true
  export AWS_DEFAULT_REGION="${MINIO_REGION:-us-east-1}"

  local uri="s3://${MINIO_KUBECONFIG_BUCKET}/${MINIO_KUBECONFIG_KEY}"
  log "uploading kubeconfig via aws s3 cp → ${uri}"
  aws s3 cp "${KUBECONFIG_PATH}" "${uri}" \
    --endpoint-url "${MINIO_ENDPOINT}" \
    --region "${MINIO_REGION:-us-east-1}" \
    ${AWS_CLI_EXTRA_ARGS:-}

  log "done (aws cli)."
  log "S3 path:     ${uri}"
}

# ---------------------------------------------------------------------------
if [[ "${USE_AWS_CLI_FOR_KUBECONFIG:-}" == "1" ]]; then
  upload_via_aws_cli
  exit 0
fi

if command -v mc >/dev/null 2>&1; then
  if upload_via_mc; then
    exit 0
  fi
  warn "mc upload failed, trying aws s3 cp as fallback…"
else
  warn "mc not found, using aws s3 cp"
fi

upload_via_aws_cli
