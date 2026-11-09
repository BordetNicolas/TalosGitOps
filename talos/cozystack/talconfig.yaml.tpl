# Fichier généré par scripts/bootstrap.sh (envsubst), flavor PLATFORM_FLAVOR=cozystack.
# Variables : CLUSTER_NAME, CLUSTER_KUBERNETES_API_HOST (= VIP de l'API), TALOS_VERSION,
# KUBERNETES_VERSION, CONTROL_PLANE_NODES_YAML, WORKER_NODES_YAML.
# Pas de Cilium inline : Cozystack installe lui-même Cilium + Kube-OVN.
---
clusterName: ${CLUSTER_NAME}
endpoint: https://${CLUSTER_KUBERNETES_API_HOST}:6443
allowSchedulingOnControlPlanes: false

talosVersion: ${TALOS_VERSION}
kubernetesVersion: ${KUBERNETES_VERSION}

cniConfig:
  name: none

patches:
  - "@./patches/cozystack-common.generated.yaml"
  - "@./patches/cluster-install-image.generated.yaml"

controlPlane:
  patches:
    - "@./patches/cozystack-controlplane.generated.yaml"

nodes:
${CONTROL_PLANE_NODES_YAML}
${WORKER_NODES_YAML}
