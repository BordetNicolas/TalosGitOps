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
require_cmd helm
require_cmd jq
require_cmd envsubst
require_cmd yq

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

read_cluster_info() {
  # Use tofu_var() (which passes -var-file and suppresses warnings) for variable
  # values, and tofu_output() for outputs that depend on live infrastructure.
  CLUSTER_NAME="$(tofu_var 'var.cluster.name' | tr -d '"')"
  CLUSTER_KUBERNETES_API_HOST="$(
    tofu_output kubernetes_api_host | jq -r 'if . == null then "" else . end' 2>/dev/null || echo ""
  )"
  TALOS_VERSION="$(tofu_var 'var.cluster.talos_version' | tr -d '"')"
  KUBERNETES_VERSION="$(tofu_var 'var.cluster.kubernetes_version' | tr -d '"')"
  INSTALL_DISK="$(tofu_var 'var.cluster.install_disk' | tr -d '"')"
  export CLUSTER_NAME CLUSTER_KUBERNETES_API_HOST TALOS_VERSION KUBERNETES_VERSION INSTALL_DISK
}

# IP du premier control-plane (tri par hostname) — cible par défaut pour talosctl
# (API :50000) quand tu ne forces pas TALOS_FETCH_*.
first_control_plane_ipv4() {
  tofu_output control_plane_nodes |
    jq -r 'to_entries | sort_by(.key) | .[0].value.ipv4'
}

read_longhorn_disk_count() {
  LONGHORN_DISK_COUNT="$(tofu_var 'length(var.worker.longhorn_disks)' | tr -d '"')"
  export LONGHORN_DISK_COUNT
}

render_cilium_inline_manifest() {
  local out="${TALOS_DIR}/patches/cilium-inline-manifest.generated.yaml"

  log "rendering Cilium ${CILIUM_CHART_VERSION:-1.16.4} as Talos inline manifest"
  helm repo add cilium https://helm.cilium.io >/dev/null 2>&1 || true
  helm repo update cilium >/dev/null 2>&1

  {
    printf 'cluster:\n'
    printf '  inlineManifests:\n'
    printf '    - name: cilium-bootstrap\n'
    printf '      contents: |\n'
    # Cilium chart embeds "${BIN_PATH}/..." for the in-container shell; talhelper
    # runs strict envsubst on merged YAML and would fail without BIN_PATH set.
    # $${...} survives envsubst as ${...} in the final manifest.
    helm template cilium cilium/cilium \
      --namespace kube-system \
      --version "${CILIUM_CHART_VERSION:-1.16.4}" \
      --values "${BOOTSTRAP_DIR}/cilium-values.yaml" \
      --set k8sServiceHost="${CLUSTER_KUBERNETES_API_HOST}" \
      --set k8sServicePort=6443 \
      | sed 's/\${BIN_PATH}/$${BIN_PATH}/g' \
      | sed 's/^/        /'
  } > "$out"

  log "Cilium inline manifest → ${out}"
}

render_cluster_network_patch() {
  local out="${TALOS_DIR}/patches/cluster-network.generated.yaml"
  cp "${TALOS_DIR}/patches/cluster-network-dhcp.yaml" "$out"
  log "rendered ${out}"
}

# Build YAML fragments listing every control-plane and worker node (IP DHCP / guest agent).
render_nodes_yaml() {
  CONTROL_PLANE_NODES_YAML="$(
    tofu_output control_plane_nodes |
      jq -r --arg disk "${INSTALL_DISK}" '
        to_entries | sort_by(.key)
        | map(
            "  - hostname: \(.key)\n"
            + "    ipAddress: \(.value.ipv4)\n"
            + "    installDisk: \($disk)\n"
            + "    controlPlane: true"
          )
        | join("\n")
      '
  )"

  WORKER_NODES_YAML="$(
    tofu_output worker_nodes |
      jq -r --arg disk "${INSTALL_DISK}" '
        to_entries | sort_by(.key)
        | map(
            "  - hostname: \(.key)\n"
            + "    ipAddress: \(.value.ipv4)\n"
            + "    installDisk: \($disk)\n"
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
    # Disques extra OpenTofu : scsi1, scsi2, … Sous Proxmox + virtio-scsi, le by-id
    # est en pratique scsi-0QEMU_QEMU_HARDDISK_drive-scsi<N> (pas …_longhorn-0).
    for ((i = 0; i < LONGHORN_DISK_COUNT; i++)); do
      scsi_idx=$((i + 1))
      cat <<EOF
    - device: /dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_drive-scsi${scsi_idx}
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

# CertSANs cluster + eth0 DHCP sur les masters.
render_controlplane_patches() {
  local out_cluster="${TALOS_DIR}/patches/controlplane.generated.yaml"
  local out_cp="${TALOS_DIR}/patches/controlplane-eth-dhcp.generated.yaml"
  envsubst '${CLUSTER_KUBERNETES_API_HOST}${CLUSTER_NAME}' \
    <"${TALOS_DIR}/patches/controlplane-cluster.yaml" >"$out_cluster"
  cp "${TALOS_DIR}/patches/controlplane-eth-dhcp.yaml" "$out_cp"
  log "rendered ${out_cluster} and ${out_cp}"
}

render_talconfig() {
  local out="${TALOS_DIR}/talconfig.yaml"
  # Ne substituer QUE ces variables (évite d’étendre par erreur d’autres $FOO
  # présents dans des commentaires ou le YAML injecté).
  envsubst '${CLUSTER_NAME}${CLUSTER_KUBERNETES_API_HOST}${TALOS_VERSION}${KUBERNETES_VERSION}${CONTROL_PLANE_NODES_YAML}${WORKER_NODES_YAML}' \
    <"${TALOS_DIR}/talconfig.yaml.tpl" >"$out"
  log "rendered ${out}"
}

# ---------------------------------------------------------------------------
# Subcommands
# ---------------------------------------------------------------------------

cmd_render() {
  # tofu output reads cached state — the guest agent IP may not be populated yet
  # if VMs were still booting during `tofu apply`.  Refresh state from Proxmox on
  # each retry so the guest agent has a chance to report.
  local attempt=1
  while true; do
    read_cluster_info
    [[ -n "${CLUSTER_KUBERNETES_API_HOST}" && "${CLUSTER_KUBERNETES_API_HOST}" != "null" ]] && break
    if (( attempt >= 40 )); then
      die "kubernetes_api_host still null after ${attempt} attempts (~10 min).
  Workarounds:
    • Set cluster.kubernetes_api_host in clusters/${CLUSTER}/terraform.tfvars and rerun.
    • Check VMs are reachable in Proxmox and qemu-guest-agent extension is active."
    fi
    warn "guest agent IP not yet available (attempt ${attempt}/40) — refreshing tofu state..."
    tofu -chdir="${TOFU_DIR}" apply -refresh-only -auto-approve \
      -var-file="${TOFU_VARS}" >/dev/null 2>&1 || true
    sleep 15
    attempt=$(( attempt + 1 ))
  done

  read_longhorn_disk_count
  render_cluster_network_patch
  render_controlplane_patches
  render_nodes_yaml
  render_cilium_inline_manifest
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
      tofu_output control_plane_nodes |
        jq -r 'to_entries[] | "\(.key)\t\(.value.ipv4)"'
      tofu_output worker_nodes |
        jq -r 'to_entries[] | "\(.key)\t\(.value.ipv4)"'
    }
  )

  log "all configs applied; nodes will reboot into Talos"
}

cmd_bootstrap() {
  read_cluster_info
  local first_cp_ip
  first_cp_ip="$(first_control_plane_ipv4)"

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
  [[ -f "${TALOSCONFIG_PATH}" ]] ||
    die "missing ${TALOSCONFIG_PATH}; run 'make talos-config' (talhelper genconfig) first"

  # talosctl parle à l’API Talos :50000 ; défaut = premier CP. TALOS_FETCH_* pour forcer.
  local default_transport
  default_transport="$(first_control_plane_ipv4)"
  [[ -n "${default_transport}" && "${default_transport}" != "null" ]] ||
    die "could not determine first control-plane IP from tofu outputs (needed for talosctl kubeconfig)"
  local nodes="${TALOS_FETCH_NODES:-$default_transport}"
  local endpoints="${TALOS_FETCH_ENDPOINTS:-$nodes}"
  if [[ -n "${TALOS_FETCH_NODES:-}" || -n "${TALOS_FETCH_ENDPOINTS:-}" ]]; then
    log "talosctl maintenance API : nodes=${nodes} endpoints=${endpoints} (TALOS_FETCH_* ; défaut sinon : ${default_transport})"
  else
    log "talosctl maintenance API : nodes=${nodes} endpoints=${endpoints} (défaut = 1er CP ; kubeconfig → https://${CLUSTER_KUBERNETES_API_HOST}:6443)"
  fi
  log "(kubectl utilisera le fichier : ${KUBECONFIG_PATH} — pas talosconfig)"

  local attempt=1
  local errf
  errf="$(mktemp)"
  trap 'rm -f "${errf}"' RETURN

  while ! talosctl \
    --nodes "${nodes}" \
    --endpoints "${endpoints}" \
    kubeconfig --force "${KUBECONFIG_PATH}" 2>"${errf}"
  do
    if (( attempt % 6 == 0 )); then
      warn "talosctl kubeconfig échoue encore (essai ${attempt}/60), dernières lignes talosctl :"
      tail -n 8 "${errf}" >&2 || true
    fi
    if (( attempt >= 60 )); then
      err "impossible d'obtenir le kubeconfig après ${attempt} essais. Stderr talosctl :"
      cat "${errf}" >&2
      rm -f "${errf}"
      trap - RETURN
      die "réseau : joindre l'API Talos :50000 sur nodes=${nodes} endpoints=${endpoints}. Vérifie tofu output control_plane_nodes, firewall, ou exporte TALOS_FETCH_NODES / TALOS_FETCH_ENDPOINTS. TALOSCONFIG=${TALOSCONFIG_PATH}"
    fi
    sleep 5
    attempt=$((attempt + 1))
  done
  rm -f "${errf}"
  trap - RETURN

  log "kubeconfig écrit : ${KUBECONFIG_PATH}"
  log "test : export KUBECONFIG=${KUBECONFIG_PATH} && kubectl get nodes"
}

cmd_health() {
  export TALOSCONFIG="${TALOSCONFIG_PATH}"
  read_cluster_info
  local default_transport
  default_transport="$(first_control_plane_ipv4)"
  [[ -n "${default_transport}" && "${default_transport}" != "null" ]] ||
    die "could not determine first control-plane IP from tofu outputs (needed for talosctl health)"
  local nodes="${TALOS_FETCH_NODES:-$default_transport}"
  local endpoints="${TALOS_FETCH_ENDPOINTS:-$nodes}"
  log "waiting for cluster health (timeout 15m)..."
  talosctl health \
    --nodes "${nodes}" \
    --endpoints "${endpoints}" \
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
