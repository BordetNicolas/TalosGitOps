# =============================================================================
# Talos cluster on Proxmox — multi-cluster orchestration.
#
# Every target (except help) requires CLUSTER=<name> pointing to a directory
# under clusters/ that contains cluster.env and terraform.tfvars.
#
# Typical workflow for a new cluster:
#
#   1. mkdir clusters/talos-01
#      cp clusters/cluster.env.example      clusters/talos-01/cluster.env
#      cp clusters/terraform.tfvars.example clusters/talos-01/terraform.tfvars
#      $EDITOR clusters/talos-01/cluster.env
#      $EDITOR clusters/talos-01/terraform.tfvars
#
#   2. make CLUSTER=talos-01 gitops-render   # renders clusters/talos-01/gitops/
#      git add clusters/talos-01/gitops/ && git commit && git push
#
#   3. make CLUSTER=talos-01 up              # full pipeline
#
# Cozystack clusters (PLATFORM_FLAVOR=cozystack in cluster.env) add UniFi
# (VLAN + DNS), the Cozystack operator/platform bootstrap, secrets and storage
# steps to `up` — see docs/cozystack.md.
#
# Targets:
#   up               full pipeline (VMs + Talos + ArgoCD + kubeconfig)
#   down             destroy the cluster (MinIO state kept)
#   tofu-init        initialise S3 backend against MinIO
#   tofu-plan        show planned changes
#   tofu-apply       create/update VMs on Proxmox
#   tofu-publish     re-apply to push kubeconfig into MinIO
#   talos-config     render Cilium inline + Talos machineconfigs, apply to nodes
#   talos-bootstrap  run talosctl bootstrap + fetch kubeconfig
#   fetch-kubeconfig fetch kubeconfig only
#   argocd-bootstrap install ArgoCD, apply App-of-Apps root
#   upload-kubeconfig push kubeconfig to MinIO
#   gitops-render    render gitops/ templates into clusters/<name>/gitops/
#   minio-buckets    create MinIO buckets (idempotent)
#   argo-pwd         print initial ArgoCD admin password
#   status           show nodes and ArgoCD app status
#   clean            remove local generated files for this cluster
#   unifi-plan|unifi-apply|unifi-destroy   VLAN + DNS on UniFi (cozystack flavor)
#   cozystack-bootstrap  install cozy-installer + Platform Package (before ArgoCD)
#   cozystack-secrets    Cloudflare token for DNS-01 certificates
#   cozystack-storage    LINSTOR ZFS pools on the workers
#   cozystack-openbao  init/configure the tenant OpenBAO and store the Airflow secrets in it
#   cozystack-workflows-secrets  S3 artifact repository (Bucket) of the tenant cluster "workflows"
#   cozystack-tenant-cluster  register tenant k8s cluster "workflows" as an ArgoCD destination
# =============================================================================

SHELL      := /usr/bin/env bash
.SHELLFLAGS := -ec

ROOT_DIR := $(abspath $(dir $(firstword $(MAKEFILE_LIST))))
TOFU_DIR := $(ROOT_DIR)/tofu

CLUSTER ?=

ifneq ($(CLUSTER),)
  CLUSTER_DIR := $(ROOT_DIR)/clusters/$(CLUSTER)
  TOFU_VARS   := $(CLUSTER_DIR)/terraform.tfvars

  ifneq (,$(wildcard $(CLUSTER_DIR)/cluster.env))
    include $(CLUSTER_DIR)/cluster.env
    export
  endif

  # Keys are always derived from CLUSTER — override anything set in cluster.env.
  MINIO_STATE_KEY      := $(CLUSTER)/terraform.tfstate
  MINIO_KUBECONFIG_KEY := $(CLUSTER)/kubeconfig
  export CLUSTER MINIO_STATE_KEY MINIO_KUBECONFIG_KEY
endif

.PHONY: help up down init-cluster \
        unifi-init unifi-plan unifi-apply unifi-destroy \
        cozystack-bootstrap cozystack-secrets cozystack-storage cozystack-tenant-cluster cozystack-workflows-secrets cozystack-openbao \
        minio-buckets tofu-init tofu-plan tofu-apply tofu-publish \
        talos-config talos-bootstrap fetch-kubeconfig argocd-bootstrap \
        upload-kubeconfig gitops-render apply-doppler-token argo-pwd \
        status clean check-cluster

.DEFAULT_GOAL := help

help: ## Show this help message.
	@awk 'BEGIN {FS = ":.*##"; printf "Available targets:\n\n"} \
		/^[a-zA-Z0-9_.-]+:.*##/ { printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2 }' \
		$(MAKEFILE_LIST)
	@echo ""
	@echo "All targets except 'help' require CLUSTER=<name>. Example:"
	@echo "  make CLUSTER=talos-01 up"

init-cluster: ## Create a new cluster directory. Usage: make init-cluster CLUSTER=talos-02
	@test -n "$(CLUSTER)" || \
		{ echo "ERROR: CLUSTER is required. Example: make init-cluster CLUSTER=talos-02"; exit 1; }
	@test ! -d "$(ROOT_DIR)/clusters/$(CLUSTER)" || \
		{ echo "ERROR: clusters/$(CLUSTER) already exists"; exit 1; }
	mkdir -p "$(ROOT_DIR)/clusters/$(CLUSTER)"
	sed 's/name = "talos-01"/name = "$(CLUSTER)"/' \
		"$(ROOT_DIR)/clusters/terraform.tfvars.example" \
		> "$(ROOT_DIR)/clusters/$(CLUSTER)/terraform.tfvars"
	cp "$(ROOT_DIR)/clusters/cluster.env.example" \
		"$(ROOT_DIR)/clusters/$(CLUSTER)/cluster.env"
	@echo ""
	@echo "Cluster $(CLUSTER) initialized in clusters/$(CLUSTER)/."
	@echo "  1. Edit clusters/$(CLUSTER)/cluster.env     (credentials: Proxmox, MinIO, ArgoCD...)"
	@echo "  2. Edit clusters/$(CLUSTER)/terraform.tfvars (sizing, versions)"
	@echo "  3. make CLUSTER=$(CLUSTER) gitops-render && git add clusters/$(CLUSTER)/gitops/ && git push"
	@echo "  4. make CLUSTER=$(CLUSTER) up"

check-cluster:
	@test -n "$(CLUSTER)" || \
		{ echo "ERROR: CLUSTER is required. Example: make CLUSTER=talos-01 up"; exit 1; }
	@test -d "$(CLUSTER_DIR)" || \
		{ echo "ERROR: cluster directory not found: $(CLUSTER_DIR)"; exit 1; }
	@test -f "$(CLUSTER_DIR)/cluster.env" || \
		{ echo "ERROR: cluster.env missing: $(CLUSTER_DIR)/cluster.env"; exit 1; }
	@test -f "$(TOFU_VARS)" || \
		{ echo "ERROR: terraform.tfvars missing: $(TOFU_VARS)"; exit 1; }
	@: $${PROXMOX_VE_ENDPOINT?missing PROXMOX_VE_ENDPOINT (check clusters/$(CLUSTER)/cluster.env)}
	@: $${AWS_ACCESS_KEY_ID?missing AWS_ACCESS_KEY_ID}
	@: $${MINIO_ENDPOINT?missing MINIO_ENDPOINT}
	@: $${MINIO_STATE_BUCKET?missing MINIO_STATE_BUCKET}
	@: $${MINIO_KUBECONFIG_BUCKET?missing MINIO_KUBECONFIG_BUCKET}

# ---------- Pipeline ---------------------------------------------------------

minio-buckets: check-cluster ## Create state, kubeconfig and Longhorn backup buckets on MinIO (idempotent).
	$(ROOT_DIR)/scripts/ensure-minio-buckets.sh

ifeq ($(PLATFORM_FLAVOR),cozystack)
UP_STEPS := check-cluster unifi-apply tofu-init tofu-apply talos-config talos-bootstrap cozystack-bootstrap argocd-bootstrap upload-kubeconfig tofu-publish cozystack-secrets cozystack-storage
else
UP_STEPS := check-cluster tofu-init tofu-apply talos-config talos-bootstrap argocd-bootstrap apply-doppler-token upload-kubeconfig tofu-publish
endif

up: $(UP_STEPS) ## Full pipeline: VMs → Talos → ArgoCD → kubeconfig (cozystack: + UniFi, operator, storage).
	@echo "==> Cluster $(CLUSTER) ready. Run 'make CLUSTER=$(CLUSTER) argo-pwd' for the ArgoCD password."

down: check-cluster ## Destroy all resources for this cluster (MinIO state kept).
	tofu -chdir=$(TOFU_DIR) destroy -auto-approve -var-file=$(TOFU_VARS)

# ---------- OpenTofu ---------------------------------------------------------

tofu-init: check-cluster minio-buckets ## Initialise OpenTofu with the MinIO S3 backend.
	tofu -chdir=$(TOFU_DIR) init -reconfigure \
	  -backend-config="bucket=$(MINIO_STATE_BUCKET)" \
	  -backend-config="key=$(MINIO_STATE_KEY)" \
	  -backend-config="endpoints={s3=\"$(MINIO_ENDPOINT)\"}"

tofu-plan: check-cluster ## Show planned infrastructure changes.
	tofu -chdir=$(TOFU_DIR) plan -var-file=$(TOFU_VARS)

tofu-apply: check-cluster ## Provision Proxmox VMs (VM targets only; skips kubeconfig publish).
	tofu -chdir=$(TOFU_DIR) apply -auto-approve \
	  -var-file=$(TOFU_VARS) \
	  -target='null_resource.talos_iso_local' \
	  -target='proxmox_virtual_environment_file.talos_iso' \
	  -target='module.talos_cp' \
	  -target='module.talos_wk'

tofu-publish: check-cluster ## Second apply: execute kubeconfig → MinIO upload (null_resource).
	tofu -chdir=$(TOFU_DIR) apply -auto-approve -var-file=$(TOFU_VARS)

# ---------- Talos / ArgoCD ---------------------------------------------------

talos-config: check-cluster ## Render Cilium inline + Talos machineconfigs, apply to nodes.
	$(ROOT_DIR)/scripts/bootstrap.sh apply

talos-bootstrap: check-cluster ## Run talosctl bootstrap and fetch kubeconfig.
	$(ROOT_DIR)/scripts/bootstrap.sh bootstrap

fetch-kubeconfig: check-cluster ## Fetch kubeconfig only (if bootstrap already ran).
	$(ROOT_DIR)/scripts/bootstrap.sh kubeconfig

argocd-bootstrap: check-cluster ## Install ArgoCD and apply the App-of-Apps root.
	$(ROOT_DIR)/scripts/bootstrap-argocd.sh

upload-kubeconfig: check-cluster ## Push kubeconfig to MinIO.
	$(ROOT_DIR)/scripts/upload-kubeconfig.sh

gitops-render: check-cluster ## Render gitops/ templates into clusters/$(CLUSTER)/gitops/.
	$(ROOT_DIR)/scripts/gitops-render.sh

apply-doppler-token: check-cluster ## Apply Doppler service token Secret (never committed).
	@chmod +x $(ROOT_DIR)/scripts/apply-doppler-token.sh
	$(ROOT_DIR)/scripts/apply-doppler-token.sh

# ---------- UniFi (VLAN + DNS, cozystack flavor) -----------------------------
# Separate OpenTofu root (tofu/unifi), state key <cluster>/unifi.tfstate, vars in
# clusters/<name>/unifi.tfvars. Needs UNIFI_API / UNIFI_API_KEY in cluster.env.

UNIFI_DIR  := $(TOFU_DIR)/unifi
UNIFI_VARS := $(CLUSTER_DIR)/unifi.tfvars

unifi-init: check-cluster minio-buckets ## Initialise the UniFi OpenTofu root (VLAN + DNS) on MinIO.
	@test -f "$(UNIFI_VARS)" || { echo "ERROR: $(UNIFI_VARS) missing"; exit 1; }
	@: $${UNIFI_API?missing UNIFI_API} $${UNIFI_API_KEY?missing UNIFI_API_KEY}
	tofu -chdir=$(UNIFI_DIR) init -reconfigure \
	  -backend-config="bucket=$(MINIO_STATE_BUCKET)" \
	  -backend-config="key=$(CLUSTER)/unifi.tfstate" \
	  -backend-config="endpoints={s3=\"$(MINIO_ENDPOINT)\"}"

unifi-plan: unifi-init ## Preview UniFi VLAN + DNS changes.
	tofu -chdir=$(UNIFI_DIR) plan -var-file=$(UNIFI_VARS)

unifi-apply: unifi-init ## Create/update the cluster VLAN and DNS records on UniFi.
	tofu -chdir=$(UNIFI_DIR) apply -auto-approve -var-file=$(UNIFI_VARS)

unifi-destroy: unifi-init ## Remove the cluster VLAN and DNS records from UniFi.
	tofu -chdir=$(UNIFI_DIR) destroy -auto-approve -var-file=$(UNIFI_VARS)

# ---------- Cozystack --------------------------------------------------------

cozystack-bootstrap: check-cluster ## Install cozy-installer + Platform Package (CNI), wait for nodes Ready.
	$(ROOT_DIR)/scripts/bootstrap-cozystack.sh

cozystack-secrets: check-cluster ## Apply the Cloudflare token Secret used for DNS-01 certificates.
	$(ROOT_DIR)/scripts/apply-cozystack-secrets.sh

cozystack-storage: check-cluster ## Create the LINSTOR ZFS storage pools on the workers.
	$(ROOT_DIR)/scripts/cozystack-storage.sh

cozystack-workflows-secrets: check-cluster ## Wire Argo Workflows artifacts to the tenant-lab Bucket in the tenant k8s cluster "workflows".
	$(ROOT_DIR)/scripts/cozystack-workflows-secrets.sh $(or $(K8S),workflows) $(or $(TENANT_NS),tenant-lab)

cozystack-openbao: check-cluster ## Init/configure the tenant OpenBAO (static seal, k8s auth) and store the Airflow secrets.
	$(ROOT_DIR)/scripts/cozystack-openbao.sh $(or $(K8S),workflows) $(or $(TENANT_NS),tenant-lab)

cozystack-tenant-cluster: check-cluster ## Register the tenant k8s cluster "workflows" (tenant-lab) in ArgoCD.
	$(ROOT_DIR)/scripts/cozystack-register-tenant-cluster.sh $(or $(K8S),workflows) $(or $(TENANT_NS),tenant-lab)

# ---------- Operations -------------------------------------------------------

argo-pwd: check-cluster ## Print the initial ArgoCD admin password.
	@KUBECONFIG=$(CLUSTER_DIR)/kubeconfig kubectl -n argocd get secret argocd-initial-admin-secret \
	  -o jsonpath='{.data.password}' | base64 -d; echo

status: check-cluster ## Show cluster nodes and ArgoCD app status.
	@KUBECONFIG=$(CLUSTER_DIR)/kubeconfig kubectl get nodes -o wide || true
	@echo
	@KUBECONFIG=$(CLUSTER_DIR)/kubeconfig kubectl -n argocd get applications.argoproj.io || true

clean: check-cluster ## Remove local generated files for this cluster (does not touch MinIO).
	rm -f $(CLUSTER_DIR)/kubeconfig $(CLUSTER_DIR)/talosconfig
	rm -f $(ROOT_DIR)/talos/talconfig.yaml \
	      $(ROOT_DIR)/talos/talsecret.yaml \
	      $(ROOT_DIR)/talos/patches/controlplane.generated.yaml \
	      $(ROOT_DIR)/talos/patches/controlplane-eth-dhcp.generated.yaml \
	      $(ROOT_DIR)/talos/patches/cluster-install-image.generated.yaml \
	      $(ROOT_DIR)/talos/patches/cluster-network.generated.yaml \
	      $(ROOT_DIR)/talos/patches/worker.generated.yaml \
	      $(ROOT_DIR)/talos/patches/cilium-inline-manifest.generated.yaml
	rm -rf $(CLUSTER_DIR)/clusterconfig $(CLUSTER_DIR)/talos
	rm -f $(CLUSTER_DIR)/clusterconfig/worker-recovery.patch.yaml 2>/dev/null || true
