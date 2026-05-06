# ---------------------------------------------------------------------------
# Talos Image Factory: register schematic, download the custom ISO on the
# machine running OpenTofu, then upload it to the Proxmox ISO datastore.
#
# Why not proxmox_download_file (URL directe) ? Proxmox interroge l'URL depuis
# le nœud ; factory.talos.dev renvoie souvent 403 (WAF / géo / User-Agent).
# Le téléchargement depuis la poste opérateur + upload via l'API PVE évite ce
# blocage.
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
      condition     = contains([200, 201], self.status_code)
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

  cache_dir      = abspath("${path.module}/.cache")
  iso_local_path = "${local.cache_dir}/${local.iso_filename}"
}

# Download ISO locally (curl runs on the host that executes OpenTofu).
resource "null_resource" "talos_iso_local" {
  triggers = {
    iso_url = local.iso_url
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      mkdir -p "${local.cache_dir}"
      tmp="${local.iso_local_path}.part"
      rm -f "$tmp"
      curl -fSL --retry 5 --retry-delay 5 --connect-timeout 30 \
        -A "TalosOpenTofuAutomation/1.0 (+https://www.talos.dev/)" \
        -o "$tmp" \
        "${local.iso_url}"
      mv "$tmp" "${local.iso_local_path}"
    EOT
  }
}

resource "proxmox_virtual_environment_file" "talos_iso" {
  content_type = "iso"
  datastore_id = var.proxmox.iso_store
  node_name    = var.proxmox.node

  source_file {
    path      = local.iso_local_path
    file_name = local.iso_filename
  }

  depends_on = [null_resource.talos_iso_local]
}
