output "cluster_name" {
  value = var.cluster.name
}

output "cluster_endpoint" {
  description = "Kubernetes / Talos API endpoint (the shared VIP)."
  value       = format("https://%s:6443", var.cluster.endpoint_vip)
}

output "talos_endpoint" {
  description = "Talos API endpoint."
  value       = format("https://%s:50000", var.cluster.endpoint_vip)
}

output "control_plane_nodes" {
  description = "Map of control-plane node name -> { vm_id, ipv4 }."
  value = {
    for k, m in module.talos_cp : k => {
      vm_id = m.vm_id
      ipv4  = m.ipv4_addresses
    }
  }
}

output "worker_nodes" {
  description = "Map of worker node name -> { vm_id, ipv4 }."
  value = {
    for k, m in module.talos_wk : k => {
      vm_id = m.vm_id
      ipv4  = m.ipv4_addresses
    }
  }
}

output "talos_iso_id" {
  value = proxmox_download_file.talos_iso.id
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
