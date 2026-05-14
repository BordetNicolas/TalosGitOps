# ---------------------------------------------------------------------------
# Publie le kubeconfig sur MinIO via scripts/upload-kubeconfig.sh (null_resource
# local-exec). Plus fiable qu'aws_s3_object : certains déploiements MinIO refusent
# PutObject avec tags/SSE, et le provider AWS ne voit pas toujours les credentials
# quand tofu est lancé hors du Makefile.
# ---------------------------------------------------------------------------

locals {
  kubeconfig_path    = abspath("${path.module}/../clusters/${var.cluster.name}/kubeconfig")
  kubeconfig_present = fileexists(local.kubeconfig_path)
}

resource "null_resource" "kubeconfig_publish_minio" {
  count = local.kubeconfig_present ? 1 : 0

  triggers = {
    kubeconfig_sha256 = try(sha256(file(local.kubeconfig_path)), "absent")
    cluster           = var.cluster.name
    bucket            = var.minio.kubeconfig_bucket
    endpoint          = var.minio.endpoint
  }

  provisioner "local-exec" {
    command = "bash \"${abspath("${path.module}/../scripts/upload-kubeconfig.sh")}\""
    # Garantit que CLUSTER est disponible même si tofu est lancé hors du Makefile.
    environment = {
      CLUSTER = var.cluster.name
    }
  }
}
