#!/usr/bin/env bash
# Talos cluster bootstrap orchestration.
#
# Subcommands:
#   render     - render talconfig.yaml + per-role patches from OpenTofu outputs
#   genconfig  - run `talhelper genconfig` to produce per-node machineconfigs
#   apply      - render + genconfig + apply machineconfigs to every node
#   bootstrap  - run `talosctl bootstrap` on the first control-plane node
#   health     - wait for the cluster to be healthy
#   all        - apply + bootstrap + health (full sequence)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "${SCRIPT_DIR}/lib.sh"

require_cmd tofu
require_cmd talhelper
require_cmd talosctl
require_cmd jq
require_cmd envsubst
require_cmd yq

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

read_cluster_info() {
  CLUSTER_NAME="$(tofu_output_raw cluster_name)"
  CLUSTER_ENDPOINT_VIP="$(echo 'var.cluster.endpoint_vip' | tofu -chdir="${TOFU_DIR}" console | tr -d '"')"
  TALOS_VERSION="$(echo 'var.cluster.talos_version' | tofu -chdir="${TOFU_DIR}" console | tr -d '"')"
  KUBERNETES_VERSION="$(echo 'var.cluster.kubernetes_version' | tofu -chdir="${TOFU_DIR}" console | tr -d '"')"
  export CLUSTER_NAME CLUSTER_ENDPOINT_VIP TALOS_VERSION KUBERNETES_VERSION
}

read_longhorn_disk_count() {
  LONGHORN_DISK_COUNT="$(
    echo 'length(var.worker.longhorn_disks)' |
      tofu -chdir="${TOFU_DIR}" console | tr -d '"'
  )"
  export LONGHORN_DISK_COUNT
}

# Build YAML fragments listing every control-plane and worker node, with
# their IP (from the qemu-guest-agent) and role.
render_nodes_yaml() {
  CONTROL_PLANE_NODES_YAML="$(
    tofu_output control_plane_nodes |
      jq -r '
        to_entries
        | map(
            "  - hostname: \(.key)\n"
            + "    ipAddress: \(.value.ipv4)\n"
            + "    controlPlane: true"
          )
        | join("\n")
      '
  )"

  WORKER_NODES_YAML="$(
    tofu_output worker_nodes |
      jq -r '
        to_entries
        | map(
            "  - hostname: \(.key)\n"
            + "    ipAddress: \(.value.ipv4)\n"
            + "    controlPlane: false"
          )
        | join("\n")
      '
  )"

  export CONTROL_PLANE_NODES_YAML WORKER_NODES_YAML
}

# Generate the worker patch covering every Longhorn disk declared in the
# tfvars. Empty if longhorn_disks is empty (compute-only workers).
render_worker_patch() {
  local out="${TALOS_DIR}/patches/worker.generated.yaml"
  if [[ "${LONGHORN_DISK_COUNT}" -eq 0 ]]; then
    cat >"$out" <<'EOF'
# No Longhorn disks configured - workers stay compute-only.
{}
EOF
    return
  fi

  {
    cat <<'EOF'
machine:
  nodeLabels:
    node.longhorn.io/create-default-disk: config
  disks:
EOF
    for ((i = 0; i < LONGHORN_DISK_COUNT; i++)); do
      cat <<EOF
    - device: /dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_longhorn-${i}
      partitions:
        - mountpoint: /var/mnt/longhorn-${i}
EOF
    done

    cat <<'EOF'
  kubelet:
    extraMounts:
EOF
    for ((i = 0; i < LONGHORN_DISK_COUNT; i++)); do
      cat <<EOF
      - destination: /var/mnt/longhorn-${i}
        type: bind
        source: /var/mnt/longhorn-${i}
        options:
          - bind
          - rshared
          - rw
EOF
    done

    cat <<'EOF'
  udev:
    rules:
EOF
    for ((i = 0; i < LONGHORN_DISK_COUNT; i++)); do
      cat <<EOF
      - 'SUBSYSTEM=="block", ENV{ID_SERIAL}=="?*longhorn-${i}*", SYMLINK+="longhorn/longhorn-${i}"'
EOF
    done
  } >"$out"

  log "rendered ${out} with ${LONGHORN_DISK_COUNT} disk(s)"
}

# envsubst the controlplane patch (it references CLUSTER_ENDPOINT_VIP and CLUSTER_NAME).
render_controlplane_patch() {
  local out="${TALOS_DIR}/patches/controlplane.generated.yaml"
  envsubst <"${TALOS_DIR}/patches/controlplane.yaml" >"$out"
  log "rendered ${out}"
}

render_talconfig() {
  local out="${TALOS_DIR}/talconfig.yaml"
  envsubst <"${TALOS_DIR}/talconfig.yaml.tpl" >"$out"
  log "rendered ${out}"
}

# ---------------------------------------------------------------------------
# Subcommands
# ---------------------------------------------------------------------------

cmd_render() {
  read_cluster_info
  read_longhorn_disk_count
  render_nodes_yaml
  render_controlplane_patch
  render_worker_patch
  render_talconfig
}

cmd_genconfig() {
  cmd_render

  log "generating per-node machineconfigs with talhelper"
  rm -rf "${CLUSTERCONFIG_DIR}"
  ( cd "${TALOS_DIR}" && talhelper genconfig --out-dir "${CLUSTERCONFIG_DIR}" )

  cp "${CLUSTERCONFIG_DIR}/talosconfig" "${TALOSCONFIG_PATH}"
  log "talosconfig copied to ${TALOSCONFIG_PATH}"
}

cmd_apply() {
  cmd_genconfig

  read_cluster_info
  local nodes_json
  nodes_json="$(tofu -chdir="${TOFU_DIR}" output -json control_plane_nodes; tofu -chdir="${TOFU_DIR}" output -json worker_nodes)"

  # Apply machineconfig to each node. We use --insecure on the first apply
  # because the maintenance API is reachable without certs.
  while IFS=$'\t' read -r hostname ip; do
    local cfg="${CLUSTERCONFIG_DIR}/${CLUSTER_NAME}-${hostname}.yaml"
    [[ -f "$cfg" ]] || die "missing machineconfig for ${hostname}: ${cfg}"
    log "applying config to ${hostname} (${ip}) [insecure mode]"
    talosctl apply-config \
      --insecure \
      --nodes "$ip" \
      --file "$cfg"
  done < <(
    {
      tofu -chdir="${TOFU_DIR}" output -json control_plane_nodes |
        jq -r 'to_entries[] | "\(.key)\t\(.value.ipv4)"'
      tofu -chdir="${TOFU_DIR}" output -json worker_nodes |
        jq -r 'to_entries[] | "\(.key)\t\(.value.ipv4)"'
    }
  )

  log "all configs applied; nodes will reboot into Talos"
}

cmd_bootstrap() {
  read_cluster_info
  local first_cp_ip
  first_cp_ip="$(
    tofu_output control_plane_nodes |
      jq -r 'to_entries | sort_by(.key) | .[0].value.ipv4'
  )"

  [[ -n "$first_cp_ip" && "$first_cp_ip" != "null" ]] ||
    die "could not determine first control-plane IP from tofu outputs"

  export TALOSCONFIG="${TALOSCONFIG_PATH}"
  log "running talosctl bootstrap on ${first_cp_ip}"

  # Retry the bootstrap a few times - the first invocation often races with
  # the etcd service coming up after the initial machineconfig apply.
  local attempt=1
  while ! talosctl --nodes "$first_cp_ip" --endpoints "$first_cp_ip" bootstrap; do
    if (( attempt >= 30 )); then
      die "talosctl bootstrap failed after ${attempt} attempts"
    fi
    warn "bootstrap attempt ${attempt} failed, retrying in 10s..."
    sleep 10
    attempt=$((attempt + 1))
  done

  log "bootstrap succeeded; waiting for the API to come up"
  cmd_kubeconfig
  cmd_health
}

cmd_kubeconfig() {
  export TALOSCONFIG="${TALOSCONFIG_PATH}"
  read_cluster_info
  log "fetching kubeconfig via the cluster VIP (${CLUSTER_ENDPOINT_VIP})"

  # Retry until the kube-apiserver starts answering.
  local attempt=1
  while ! talosctl \
    --nodes "${CLUSTER_ENDPOINT_VIP}" \
    --endpoints "${CLUSTER_ENDPOINT_VIP}" \
    kubeconfig --force "${KUBECONFIG_PATH}" 2>/dev/null
  do
    if (( attempt >= 60 )); then
      die "could not fetch kubeconfig after ${attempt} attempts"
    fi
    sleep 5
    attempt=$((attempt + 1))
  done
  log "kubeconfig written to ${KUBECONFIG_PATH}"
}

cmd_health() {
  export TALOSCONFIG="${TALOSCONFIG_PATH}"
  read_cluster_info
  log "waiting for cluster health (timeout 15m)..."
  talosctl health \
    --nodes "${CLUSTER_ENDPOINT_VIP}" \
    --endpoints "${CLUSTER_ENDPOINT_VIP}" \
    --wait-timeout 15m
}

cmd_all() {
  cmd_apply
  cmd_bootstrap
}

# ---------------------------------------------------------------------------
# Dispatcher
# ---------------------------------------------------------------------------

main() {
  local subcommand="${1:-all}"
  shift || true

  case "$subcommand" in
    render)      cmd_render ;;
    genconfig)   cmd_genconfig ;;
    apply)       cmd_apply ;;
    bootstrap)   cmd_bootstrap ;;
    kubeconfig)  cmd_kubeconfig ;;
    health)      cmd_health ;;
    all)         cmd_all ;;
    *)           die "unknown subcommand: ${subcommand}" ;;
  esac
}

main "$@"
