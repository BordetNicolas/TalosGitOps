# ---------------------------------------------------------------------------
# Publish the kubeconfig produced by `scripts/bootstrap.sh` into the
# configured MinIO bucket. This file is created on the operator's machine
# during the Talos bootstrap step; if it does not exist yet (first apply,
# before the cluster is up), this resource is simply not created.
#
# A second `tofu apply` (target `tofu-publish` in the Makefile) picks up the
# now-existing kubeconfig and uploads it.
# ---------------------------------------------------------------------------

locals {
  kubeconfig_path    = "${path.module}/../kubeconfig"
  kubeconfig_present = fileexists(local.kubeconfig_path)
}

data "local_file" "kubeconfig" {
  count    = local.kubeconfig_present ? 1 : 0
  filename = local.kubeconfig_path
}

resource "aws_s3_object" "kubeconfig" {
  count    = local.kubeconfig_present ? 1 : 0
  provider = aws.minio

  bucket                 = var.minio.kubeconfig_bucket
  key                    = var.minio.kubeconfig_key
  content                = data.local_file.kubeconfig[0].content
  content_type           = "application/yaml"
  server_side_encryption = "AES256"

  tags = {
    cluster = var.cluster.name
    source  = "talos-tofu-automation"
  }
}
