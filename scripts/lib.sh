#!/usr/bin/env bash
# Common helpers for the Talos automation scripts.
# shellcheck shell=bash

set -euo pipefail

# Resolve the project root from the location of this file.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TOFU_DIR="${ROOT_DIR}/tofu"
TALOS_DIR="${ROOT_DIR}/talos"
BOOTSTRAP_DIR="${ROOT_DIR}/bootstrap"
GITOPS_DIR="${ROOT_DIR}/gitops"
CLUSTERCONFIG_DIR="${ROOT_DIR}/clusterconfig"

KUBECONFIG_PATH="${ROOT_DIR}/kubeconfig"
TALOSCONFIG_PATH="${ROOT_DIR}/talosconfig"

log()  { printf '\033[1;34m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
warn() { printf '\033[1;33m[%s] WARN:\033[0m %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
err()  { printf '\033[1;31m[%s] ERROR:\033[0m %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
die()  { err "$@"; exit 1; }

require_cmd() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || die "required command not found: $cmd"
}

# Read a single OpenTofu output value (as a JSON-decoded string).
tofu_output() {
  local name="$1"
  tofu -chdir="${TOFU_DIR}" output -json "$name"
}

# Read a single OpenTofu output value as a raw string (no JSON quotes).
tofu_output_raw() {
  local name="$1"
  tofu -chdir="${TOFU_DIR}" output -raw "$name"
}

# Read a tfvars value via `tofu console`. Falls back to terraform.tfvars
# direct parse if console is unavailable.
tofu_var() {
  local expression="$1"
  echo "$expression" | tofu -chdir="${TOFU_DIR}" console
}

ensure_env() {
  local var
  for var in "$@"; do
    if [[ -z "${!var:-}" ]]; then
      die "missing required environment variable: ${var} (check your .env)"
    fi
  done
}
