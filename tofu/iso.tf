# ---------------------------------------------------------------------------
# Talos Image Factory: build a custom ISO containing the requested Talos
# system extensions (qemu-guest-agent, iscsi-tools by default), then have
# Proxmox download it directly into the configured ISO datastore.
# ---------------------------------------------------------------------------

locals {
  factory_endpoint = "https://factory.talos.dev"

  schematic_yaml = yamlencode({
    customization = {
      systemExtensions = {
        officialExtensions = var.cluster.extensions
      }
    }
  })
}

# Submit the schematic to factory.talos.dev to obtain a deterministic ID.
data "http" "talos_schematic" {
  url          = "${local.factory_endpoint}/schematics"
  method       = "POST"
  request_body = local.schematic_yaml
  request_headers = {
    "Content-Type" = "application/x-yaml"
  }

  lifecycle {
    postcondition {
      condition     = self.status_code == 200
      error_message = "Talos Image Factory rejected the schematic (HTTP ${self.status_code}): ${self.response_body}"
    }
  }
}

locals {
  schematic_id = jsondecode(data.http.talos_schematic.response_body).id

  iso_url = format(
    "%s/image/%s/%s/metal-amd64.iso",
    local.factory_endpoint,
    local.schematic_id,
    var.cluster.talos_version,
  )

  iso_filename = format(
    "talos-%s-%s-metal-amd64.iso",
    var.cluster.talos_version,
    substr(local.schematic_id, 0, 8),
  )
}

resource "proxmox_download_file" "talos_iso" {
  content_type = "iso"
  datastore_id = var.proxmox.iso_store
  node_name    = var.proxmox.node

  url       = local.iso_url
  file_name = local.iso_filename

  overwrite = false
}
