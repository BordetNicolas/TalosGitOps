terraform {
  required_version = ">= 1.10.0"

  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = ">= 0.66.0"
    }
    null = {
      source  = "hashicorp/null"
      version = ">= 3.2.2"
    }
    http = {
      source  = "hashicorp/http"
      version = ">= 3.4.5"
    }
  }
}
