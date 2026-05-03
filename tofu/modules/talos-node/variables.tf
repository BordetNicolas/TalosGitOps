variable "name" {
  description = "Hostname / Proxmox VM name."
  type        = string
}

variable "vm_id" {
  description = "Proxmox VM ID (must be unique across the node)."
  type        = number
}

variable "node" {
  description = "Proxmox node where the VM is created."
  type        = string
}

variable "iso_id" {
  description = "Datastore-qualified ID of the Talos ISO (e.g. local:iso/talos.iso)."
  type        = string
}

variable "tags" {
  description = "Proxmox tags applied to the VM."
  type        = list(string)
  default     = []
}

variable "cores" {
  type = number
}

variable "memory_mb" {
  type = number
}

variable "disk_gb" {
  description = "Size of the OS disk (rootfs)."
  type        = number
}

variable "disk_store" {
  description = "Default storage pool for disks."
  type        = string
}

variable "bridge" {
  description = "Proxmox network bridge."
  type        = string
}

variable "extra_disks" {
  description = <<-EOT
    Extra disks (typically dedicated to Longhorn). Each entry creates one
    additional virtio-scsi disk on the VM with a stable serial of the form
    `longhorn-<index>`, which Talos picks up via /dev/disk/by-id/.
  EOT
  type = list(object({
    size_gb = number
    storage = optional(string)
    ssd     = optional(bool, true)
  }))
  default = []
}
