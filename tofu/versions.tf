terraform {
  required_version = ">= 1.10.0"

  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = ">= 0.66.0"
    }
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.70.0"
    }
    local = {
      source  = "hashicorp/local"
      version = ">= 2.5.1"
    }
    null = {
      source  = "hashicorp/null"
      version = ">= 3.2.2"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.6.2"
    }
    http = {
      source  = "hashicorp/http"
      version = ">= 3.4.5"
    }
  }
}
