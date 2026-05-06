provider "proxmox" {
  endpoint  = var.proxmox.endpoint
  api_token = var.proxmox.api_token
  insecure  = var.proxmox.insecure

  ssh {
    agent    = true
    username = var.proxmox.ssh_username
  }
}
