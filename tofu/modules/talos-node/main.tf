terraform {
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = ">= 0.66.0"
    }
  }
}

resource "proxmox_virtual_environment_vm" "this" {
  name        = var.name
  node_name   = var.node
  vm_id       = var.vm_id
  tags        = var.tags
  description = "Managed by Talos OpenTofu automation."

  bios          = "seabios"
  machine       = "q35"
  on_boot       = true
  started       = true
  scsi_hardware = "virtio-scsi-single"

  agent {
    enabled = true
    timeout = "5m"
    trim    = true
  }

  cpu {
    cores = var.cores
    type  = "host"
  }

  memory {
    dedicated = var.memory_mb
  }

  network_device {
    bridge  = var.bridge
    model   = "virtio"
    vlan_id = var.vlan_tag
  }

  cdrom {
    enabled   = true
    file_id   = var.iso_id
    interface = "ide2"
  }

  # OS disk
  disk {
    interface    = "scsi0"
    datastore_id = var.disk_store
    size         = var.disk_gb
    discard      = "on"
    ssd          = true
    file_format  = "raw"
    iothread     = true
  }

  # Additional Longhorn disks (workers only). serial=longhorn-<n> (debug / udev).
  # Sous PVE + virtio-scsi, Talos voit plutôt …/scsi-0QEMU_QEMU_HARDDISK_drive-scsi<N>
  # (N = 1,2,… = scsi1,scsi2…) — cf. scripts/bootstrap.sh render_worker_patch.
  dynamic "disk" {
    for_each = { for i, d in var.extra_disks : i => d }
    content {
      interface    = "scsi${disk.key + 1}"
      datastore_id = coalesce(disk.value.storage, var.disk_store)
      size         = disk.value.size_gb
      discard      = "on"
      ssd          = coalesce(disk.value.ssd, true)
      serial       = "longhorn-${disk.key}"
      file_format  = "raw"
      iothread     = true
    }
  }

  boot_order = ["scsi0", "ide2"]

  operating_system {
    type = "l26"
  }

  serial_device {}

  lifecycle {
    # Talos installs the OS image onto scsi0 then reboots without the ISO,
    # so we ignore drift on the cdrom block to avoid spurious recreates.
    ignore_changes = [
      cdrom,
      started,
    ]
  }
}

locals {
  ipv4_from_guest_agent = try(
    [
      for addrs in proxmox_virtual_environment_vm.this.ipv4_addresses :
      addrs[0]
      if length(addrs) > 0 && addrs[0] != "127.0.0.1"
    ][0],
    null,
  )
}

output "vm_id" {
  value = proxmox_virtual_environment_vm.this.vm_id
}

output "name" {
  value = proxmox_virtual_environment_vm.this.name
}

output "ipv4_addresses" {
  description = "IPv4 remontée par le qemu-guest-agent Proxmox (DHCP). Null tant que l’agent n’a pas d’IP."
  value       = local.ipv4_from_guest_agent
}
