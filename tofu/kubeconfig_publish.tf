# ---------------------------------------------------------------------------
# Publie le kubeconfig sur MinIO en exécutant scripts/upload-kubeconfig.sh depuis
# un null_resource (local-exec). Plus fiable que aws_s3_object : beaucoup de
# déploiements MinIO refusent PutObject avec tags / SSE, et les credentials ne
# sont pas toujours visibles pour le provider AWS quand OpenTofu est lancé hors
# du Makefile. Le script charge .env via lib.sh et utilise `mc` (ou repli AWS
# CLI si configuré).
# ---------------------------------------------------------------------------

locals {
  kubeconfig_path    = abspath("${path.module}/../kubeconfig")
  kubeconfig_present = fileexists(local.kubeconfig_path)
}

resource "null_resource" "kubeconfig_publish_minio" {
  count = local.kubeconfig_present ? 1 : 0

  triggers = {
    # try() : évite une erreur de plan quand le fichier n'existe pas encore
    # (même si count=0, certains runtimes évaluent quand même les triggers).
    kubeconfig_sha256 = try(sha256(file(local.kubeconfig_path)), "absent")
    bucket            = var.minio.kubeconfig_bucket
    key               = var.minio.kubeconfig_key
    endpoint          = var.minio.endpoint
    cluster           = var.cluster.name
  }

  provisioner "local-exec" {
    # Invoquer bash explicitement : le défaut de local-exec est /bin/sh (souvent dash),
    # où `source` n’existe pas. `upload-kubeconfig.sh` charge `.env` via `lib.sh`.
    command = "bash \"${abspath("${path.module}/../scripts/upload-kubeconfig.sh")}\""
  }
}
