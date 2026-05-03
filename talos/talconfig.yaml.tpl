# Talhelper configuration template, rendered by `scripts/bootstrap.sh`.
# Variables substituted at runtime (envsubst):
#   $CLUSTER_NAME             - cluster.name
#   $CLUSTER_ENDPOINT_VIP     - cluster.endpoint_vip
#   $TALOS_VERSION            - cluster.talos_version
#   $KUBERNETES_VERSION       - cluster.kubernetes_version
#   $CONTROL_PLANE_NODES_YAML - generated `nodes:` entries for control-plane
#   $WORKER_NODES_YAML        - generated `nodes:` entries for workers
---
clusterName: ${CLUSTER_NAME}
endpoint: https://${CLUSTER_ENDPOINT_VIP}:6443
allowSchedulingOnControlPlanes: false

talosVersion: ${TALOS_VERSION}
kubernetesVersion: ${KUBERNETES_VERSION}

cniConfig:
  name: none

# Cluster-wide patches applied to every node.
patches:
  - "@./patches/cluster-common.yaml"

controlPlane:
  patches:
    - "@./patches/controlplane.generated.yaml"

worker:
  patches:
    - "@./patches/worker.generated.yaml"

nodes:
${CONTROL_PLANE_NODES_YAML}
${WORKER_NODES_YAML}
