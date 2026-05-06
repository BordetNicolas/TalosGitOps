locals {
  control_plane_keys_sorted = sort(keys(module.talos_cp))

  first_control_plane_key = length(local.control_plane_keys_sorted) > 0 ? local.control_plane_keys_sorted[0] : null

  first_control_plane_ipv4 = local.first_control_plane_key != null ? module.talos_cp[local.first_control_plane_key].ipv4_addresses : null

  # Surcharge optionnelle dans tfvars ; sinon IP DHCP du premier control plane (guest agent).
  _kubernetes_api_override = var.cluster.kubernetes_api_host == null ? "" : trimspace(var.cluster.kubernetes_api_host)

  kubernetes_api_host_effective = local._kubernetes_api_override != "" ? local._kubernetes_api_override : local.first_control_plane_ipv4
}
