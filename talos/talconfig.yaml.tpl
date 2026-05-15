# Fichier généré par scripts/bootstrap.sh (envsubst). Ne pas éditer à la main.
# Variables : CLUSTER_NAME, CLUSTER_KUBERNETES_API_HOST, TALOS_VERSION,
# KUBERNETES_VERSION, CONTROL_PLANE_NODES_YAML, WORKER_NODES_YAML.
---
clusterName: ${CLUSTER_NAME}
endpoint: https://${CLUSTER_KUBERNETES_API_HOST}:6443
allowSchedulingOnControlPlanes: false

talosVersion: ${TALOS_VERSION}
kubernetesVersion: ${KUBERNETES_VERSION}

cniConfig:
  name: none

# Cluster-wide patches applied to every node.
patches:
  - "@./patches/cluster-common-base.yaml"
  - "@./patches/cluster-install-image.generated.yaml"
  - "@./patches/cluster-network.generated.yaml"
  - "@./patches/cilium-inline-manifest.generated.yaml"

controlPlane:
  patches:
    - "@./patches/controlplane.generated.yaml"
    - "@./patches/controlplane-eth-dhcp.generated.yaml"
    - "@./patches/controlplane-api-access.yaml"

worker:
  patches:
    - "@./patches/worker.generated.yaml"

nodes:
${CONTROL_PLANE_NODES_YAML}
${WORKER_NODES_YAML}
