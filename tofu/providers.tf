provider "proxmox" {
  endpoint  = var.proxmox.endpoint
  api_token = var.proxmox.api_token
  insecure  = var.proxmox.insecure

  ssh {
    agent    = true
    username = var.proxmox.ssh_username
  }
}

provider "aws" {
  alias  = "minio"
  region = var.minio.region

  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_region_validation      = true
  skip_requesting_account_id  = true
  s3_use_path_style           = true

  endpoints {
    s3 = var.minio.endpoint
  }
}
