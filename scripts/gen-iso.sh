#!/usr/bin/env bash
# Generate a Talos custom ISO via factory.talos.dev and print the resulting URL.
# This is provided as a manual escape hatch in case the OpenTofu-driven download
# inside Proxmox is not reachable from the operator's machine.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "${SCRIPT_DIR}/lib.sh"

require_cmd curl
require_cmd jq

TALOS_VERSION="${TALOS_VERSION:-v1.8.4}"
SCHEMATIC_FILE="${1:-${TALOS_DIR}/schematic.yaml}"

[[ -f "$SCHEMATIC_FILE" ]] || die "schematic file not found: $SCHEMATIC_FILE"

log "submitting schematic to factory.talos.dev (Talos $TALOS_VERSION)"
SCHEMATIC_ID="$(
  curl -fsS -X POST \
    -H 'Content-Type: application/x-yaml' \
    --data-binary "@${SCHEMATIC_FILE}" \
    https://factory.talos.dev/schematics |
    jq -r '.id'
)"

[[ -n "$SCHEMATIC_ID" && "$SCHEMATIC_ID" != "null" ]] ||
  die "factory returned an empty schematic id"

ISO_URL="https://factory.talos.dev/image/${SCHEMATIC_ID}/${TALOS_VERSION}/metal-amd64.iso"

log "schematic id: ${SCHEMATIC_ID}"
log "ISO URL:      ${ISO_URL}"
echo "${ISO_URL}"
