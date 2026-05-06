locals {
  iso_id = proxmox_virtual_environment_file.talos_iso.id

  control_plane_nodes = {
    for i in range(var.control_plane.count) :
    format("%s-cp-%d", var.cluster.name, i) => {
      vm_id    = var.vm_id_base + i
      cp_index = i
    }
  }

  worker_nodes = {
    for i in range(var.worker.count) :
    format("%s-wk-%d", var.cluster.name, i) => {
      vm_id    = var.vm_id_base + 100 + i
      wk_index = i
    }
  }
}

module "talos_cp" {
  source   = "./modules/talos-node"
  for_each = local.control_plane_nodes

  name       = each.key
  vm_id      = each.value.vm_id
  node       = var.proxmox.node
  iso_id     = local.iso_id
  tags       = ["talos", "controlplane", var.cluster.name]
  cores      = var.control_plane.cores
  memory_mb  = var.control_plane.memory_mb
  disk_gb    = var.control_plane.disk_gb
  disk_store   = var.proxmox.disk_store
  bridge       = var.proxmox.bridge
  vlan_tag     = try(var.proxmox.vlan_tag, null)

  extra_disks = []
}

module "talos_wk" {
  source   = "./modules/talos-node"
  for_each = local.worker_nodes

  name       = each.key
  vm_id      = each.value.vm_id
  node       = var.proxmox.node
  iso_id     = local.iso_id
  tags       = ["talos", "worker", var.cluster.name]
  cores      = var.worker.cores
  memory_mb  = var.worker.memory_mb
  disk_gb    = var.worker.disk_gb
  disk_store   = var.proxmox.disk_store
  bridge       = var.proxmox.bridge
  vlan_tag     = try(var.proxmox.vlan_tag, null)

  extra_disks = var.worker.longhorn_disks
}
