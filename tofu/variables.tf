variable "proxmox" {
  description = "Proxmox VE connection details and default datastores."
  type = object({
    endpoint     = string
    api_token    = string
    insecure     = optional(bool, false)
    node         = optional(string, "pve1")
    iso_store    = optional(string, "local")
    disk_store   = optional(string, "local-lvm")
    bridge       = optional(string, "vmbr0")
    # Tag 802.1Q sur la vNIC (bridge vlan-aware côté hôte). Null = trafic non tagué.
    vlan_tag     = optional(number, null)
    ssh_username = optional(string, "root")
  })
  sensitive = true
}

variable "cluster" {
  description = <<-EOT
    Identité du cluster et versions.
    kubernetes_api_host (optionnel) : surcharger l’hôte API (DNS ou IP fixe). Sinon,
    l’IP du premier control plane telle que remontée par Proxmox (DHCP / guest agent)
    est utilisée pour talconfig, certSANs et Cilium.
    install_disk : disque d’installation Talos (talhelper `nodes[].installDisk`).
    Avec le layout Proxmox par défaut (virtio-scsi, OS sur scsi0), en général /dev/sda.
    Utilise /dev/vda si le disque est uniquement virtio-blk.
  EOT
  type = object({
    name                  = string
    kubernetes_api_host   = optional(string)
    talos_version      = optional(string, "v1.8.4")
    kubernetes_version = optional(string, "1.31.4")
    install_disk       = optional(string, "/dev/sda")
    extensions = optional(list(string), [
      "siderolabs/qemu-guest-agent",
      "siderolabs/iscsi-tools",
    ])
  })
}

variable "control_plane" {
  description = "Control-plane node sizing. `count` is the number of masters."
  type = object({
    count     = number
    cores     = number
    memory_mb = number
    disk_gb   = number
  })
  default = {
    count     = 3
    cores     = 2
    memory_mb = 4096
    disk_gb   = 50
  }

  validation {
    condition     = var.control_plane.count >= 1 && var.control_plane.count % 2 == 1
    error_message = "control_plane.count must be an odd number >= 1 (1, 3, 5, ...) for etcd quorum."
  }
}

variable "worker" {
  description = <<-EOT
    Worker node sizing. `count` is the number of workers, `disk_gb` is the OS
    rootfs disk and `longhorn_disks` is a list of additional disks dedicated
    to Longhorn storage. Each entry is mounted on /var/mnt/longhorn-<index>
    inside Talos.
  EOT
  type = object({
    count     = number
    cores     = number
    memory_mb = number
    disk_gb   = number
    longhorn_disks = optional(list(object({
      size_gb = number
      storage = optional(string)
      ssd     = optional(bool, true)
    })), [{ size_gb = 100 }])
  })
  default = {
    count          = 3
    cores          = 4
    memory_mb      = 8192
    disk_gb        = 50
    longhorn_disks = [{ size_gb = 100 }]
  }
}

variable "metallb_pool" {
  description = "Inclusive IP range advertised by MetalLB in L2 mode."
  type = object({
    start = string
    end   = string
  })
}

variable "argocd" {
  description = "GitOps source of truth and ArgoCD UI exposure."
  type = object({
    git_repo_url  = string
    git_revision  = optional(string, "main")
    git_path      = optional(string, "gitops")
    ingress_host  = optional(string, "argocd.lan")
    chart_version = optional(string, "7.7.7")
    image_tag     = optional(string, "v2.13.1")
  })
}

variable "minio" {
  description = "MinIO endpoint and bucket layout for tfstate + kubeconfig."
  type = object({
    endpoint          = string
    region            = optional(string, "us-east-1")
    state_bucket      = string
    state_key         = optional(string, "talos-pve1/terraform.tfstate")
    kubeconfig_bucket = string
    kubeconfig_key    = optional(string, "talos-pve1/kubeconfig")
  })
}

variable "vm_id_base" {
  description = <<-EOT
    Starting VMID for the cluster. Control-plane VMs use vm_id_base..+count-1,
    workers use vm_id_base+100..+100+count-1. Adjust if these IDs collide with
    existing VMs on the Proxmox node.
  EOT
  type        = number
  default     = 9000
}
