output "cluster_name" {
  value = var.cluster.name
}

output "kubernetes_api_host" {
  description = "Hôte API K8s/Talos effectif (override tfvars ou premier CP, IP DHCP / guest agent)."
  value       = local.kubernetes_api_host_effective
}

output "cluster_endpoint" {
  description = "URL API Kubernetes (https://hôte:6443) une fois l’hôte effectif connu."
  value       = local.kubernetes_api_host_effective != null ? format("https://%s:6443", local.kubernetes_api_host_effective) : null
}

output "talos_endpoint" {
  description = "URL API Talos maintenance (même hôte que l’API Kubernetes)."
  value       = local.kubernetes_api_host_effective != null ? format("https://%s:50000", local.kubernetes_api_host_effective) : null
}

output "control_plane_nodes" {
  description = "Par nœud : vm_id, ipv4 (DHCP / qemu-guest-agent Proxmox)."
  value = {
    for k, m in module.talos_cp : k => {
      vm_id = m.vm_id
      ipv4  = m.ipv4_addresses
    }
  }
}

output "worker_nodes" {
  description = "Par nœud : vm_id, ipv4 (DHCP / qemu-guest-agent Proxmox)."
  value = {
    for k, m in module.talos_wk : k => {
      vm_id = m.vm_id
      ipv4  = m.ipv4_addresses
    }
  }
}

output "talos_iso_id" {
  value = proxmox_virtual_environment_file.talos_iso.id
}

output "schematic_id" {
  value = local.schematic_id
}

output "kubeconfig_object_url" {
  description = "MinIO S3 URL where the kubeconfig has been uploaded (empty until the cluster is bootstrapped)."
  value = local.kubeconfig_present ? format(
    "%s/%s/%s",
    trimsuffix(var.minio.endpoint, "/"),
    var.minio.kubeconfig_bucket,
    var.minio.kubeconfig_key,
  ) : ""
}
