#!/usr/bin/env bash
# Common helpers for the Talos automation scripts.
# shellcheck shell=bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# CLUSTER must be set in the environment (by the Makefile or by the operator).
: "${CLUSTER:?CLUSTER must be set — e.g. export CLUSTER=talos-01 or make CLUSTER=talos-01 <target>}"

CLUSTER_DIR="${ROOT_DIR}/clusters/${CLUSTER}"

# Load cluster-specific env (also sourced here so scripts work outside make).
if [[ -f "${CLUSTER_DIR}/cluster.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "${CLUSTER_DIR}/cluster.env"
  set +a
fi

# Paths — all cluster-specific artifacts live under clusters/${CLUSTER}/.
TOFU_DIR="${ROOT_DIR}/tofu"
TOFU_VARS="${CLUSTER_DIR}/terraform.tfvars"
TALOS_DIR="${ROOT_DIR}/talos"
BOOTSTRAP_DIR="${ROOT_DIR}/bootstrap"
GITOPS_TEMPLATES_DIR="${ROOT_DIR}/gitops"
GITOPS_DIR="${CLUSTER_DIR}/gitops"
CLUSTERCONFIG_DIR="${CLUSTER_DIR}/clusterconfig"
KUBECONFIG_PATH="${CLUSTER_DIR}/kubeconfig"
TALOSCONFIG_PATH="${CLUSTER_DIR}/talosconfig"

# MinIO keys are always derived from the cluster name (overridable via cluster.env).
MINIO_STATE_KEY="${MINIO_STATE_KEY:-${CLUSTER}/terraform.tfstate}"
MINIO_KUBECONFIG_KEY="${MINIO_KUBECONFIG_KEY:-${CLUSTER}/kubeconfig}"
export MINIO_STATE_KEY MINIO_KUBECONFIG_KEY

log()  { printf '\033[1;34m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
warn() { printf '\033[1;33m[%s] WARN:\033[0m %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
err()  { printf '\033[1;31m[%s] ERROR:\033[0m %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
die()  { err "$@"; exit 1; }

require_cmd() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || die "required command not found: $cmd"
}

# Strip CSI color sequences (OpenTofu prints colorized diagnostics on stdout).
_tofu_strip_ansi() {
  sed $'s/\e\[[0-9;]*m//g'
}

# Strip framed diagnostic lines (╷ │ ╵) after ANSI removal so ^ matches.
_tofu_strip_box_diags() {
  LC_ALL=C.UTF-8 grep -vE '^[[:space:]]*(╷|│|╵)' || true
}

# Strip noise OpenTofu may print on stdout before JSON (same root cause as tofu_var).
_tofu_strip_warnings() {
  _tofu_strip_ansi | _tofu_strip_box_diags
}

# Read an OpenTofu output value as JSON (stderr suppressed, warnings stripped).
tofu_output() {
  local name="$1"
  tofu -chdir="${TOFU_DIR}" output -json "$name" 2>/dev/null | _tofu_strip_warnings
}

# Read an OpenTofu output value as a raw string.
tofu_output_raw() {
  local name="$1"
  tofu -chdir="${TOFU_DIR}" output -raw "$name" 2>/dev/null
}

# Evaluate a tfvars expression via `tofu console` (cluster tfvars).
# Diagnostics (undeclared var warnings, etc.) can be colorized on stdout; strip
# them and keep the last non-empty line (all current callers expect a scalar).
tofu_var() {
  local expression="$1"
  echo "$expression" \
    | tofu -chdir="${TOFU_DIR}" console -compact-warnings -var-file="${TOFU_VARS}" 2>/dev/null \
    | _tofu_strip_ansi \
    | _tofu_strip_box_diags \
    | LC_ALL=C.UTF-8 sed '/^[[:space:]]*[Ww]arning:/d' \
    | sed '/^[[:space:]]*$/d' \
    | tail -n 1
}

ensure_env() {
  local var
  for var in "$@"; do
    if [[ -z "${!var:-}" ]]; then
      die "missing required environment variable: ${var} (check clusters/${CLUSTER}/cluster.env)"
    fi
  done
}

# Slug d'environnement pour les hostnames ingress (<service>-<env>.<domaine>).
# Défaut : CLUSTER sans préfixe « talos- » (ex. talos-02 → 02).
platform_env() {
  local env="${PLATFORM_ENV:-}"
  if [[ -z "$env" ]]; then
    env="${CLUSTER#talos-}"
    [[ "$env" == "$CLUSTER" ]] && env="$CLUSTER"
  fi
  printf '%s' "$env"
}

# argocd / longhorn / grafana → argocd-02.example.com ou argocd.example.com si prd|prod.
platform_ingress_host() {
  local service="$1"
  local env domain
  env="$(platform_env)"
  domain="${PLATFORM_INGRESS_DOMAIN:-${CLOUDFLARE_DOMAIN:-}}"
  [[ -n "$domain" ]] || die "CLOUDFLARE_DOMAIN (or PLATFORM_INGRESS_DOMAIN) required for ingress hostnames"
  case "${env,,}" in
    prd|prod) printf '%s.%s' "$service" "$domain" ;;
    *) printf '%s-%s.%s' "$service" "$env" "$domain" ;;
  esac
}

# Renseigne ARGOCD_INGRESS_HOST / LONGHORN_INGRESS_HOST / GRAFANA_INGRESS_HOST si absents.
export_platform_ingress_hosts() {
  export ARGOCD_INGRESS_HOST="${ARGOCD_INGRESS_HOST:-$(platform_ingress_host argocd)}"
  export LONGHORN_INGRESS_HOST="${LONGHORN_INGRESS_HOST:-$(platform_ingress_host longhorn)}"
  export GRAFANA_INGRESS_HOST="${GRAFANA_INGRESS_HOST:-$(platform_ingress_host grafana)}"
}
