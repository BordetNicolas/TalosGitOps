# homelab-apps — repo applications (workloads)

Dépôt Git **séparé** du repo plateforme TalosGitOps. ArgoCD y accède via l’Application `workloads-root` (`clusters/<CLUSTER>/apps/`).

## Structure

```text
homelab-apps/
  clusters/
    talos-02/
      apps/              # manifests Application ArgoCD
      manifests/         # manifests Kubernetes (optionnel)
```

## Bootstrap

1. Créer le repo public `homelab-apps` sur GitHub.
2. Copier le contenu de `examples/homelab-apps/clusters/` à la racine du nouveau repo.
3. Dans `clusters/<CLUSTER>/cluster.env` (repo plateforme) : `APPS_GIT_REPO` / `APPS_GIT_REVISION`.
4. `make CLUSTER=<name> gitops-render` puis commit/push TalosGitOps.

## Exemple

Voir `clusters/talos-02/apps/10-whoami.yaml` et les manifests associés.
