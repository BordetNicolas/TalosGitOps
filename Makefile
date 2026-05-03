# =============================================================================
# Talos cluster on Proxmox - top-level orchestration.
#
# Loads `.env` (gitignored) and exports every variable to OpenTofu and the
# helper scripts. The most common workflow is:
#
#   1. cp .env.example .env && $EDITOR .env
#   2. cp tofu/terraform.tfvars.example tofu/terraform.tfvars && $EDITOR ...
#   3. make gitops-render            # one-time, then commit + push gitops/
#   4. make up                       # provision + bootstrap + GitOps takeover
#
# Targets:
#   up                    full pipeline (default)
#   down                  destroy the cluster (state stays in MinIO)
#   tofu-init             initialise the S3 backend against MinIO
#   tofu-plan             show planned changes
#   tofu-apply            create/update VMs on Proxmox
#   tofu-publish          re-apply to push the kubeconfig into MinIO
#   talos-config          render + apply Talos machineconfigs
#   talos-bootstrap       run `talosctl bootstrap` + fetch kubeconfig
#   argocd-bootstrap      install Cilium + ArgoCD, hand control to GitOps
#   upload-kubeconfig     push kubeconfig to MinIO via mc
#   gitops-render         substitute placeholders in gitops/ from .env
#   argo-pwd              print the initial ArgoCD admin password
#   status                show cluster nodes and ArgoCD app status
#   clean                 remove local generated files (kubeconfig, ...)
# =============================================================================

SHELL := /usr/bin/env bash
.SHELLFLAGS := -ec

ROOT_DIR := $(abspath $(dir $(firstword $(MAKEFILE_LIST))))
TOFU_DIR := $(ROOT_DIR)/tofu

# Load .env if present and export every variable to recipes.
ifneq (,$(wildcard $(ROOT_DIR)/.env))
include $(ROOT_DIR)/.env
export
endif

.PHONY: help up down \
        tofu-init tofu-plan tofu-apply tofu-publish \
        talos-config talos-bootstrap argocd-bootstrap \
        upload-kubeconfig gitops-render argo-pwd \
        status clean check-env

# ---------- Pipeline ---------------------------------------------------------
.DEFAULT_GOAL := help

help: ## Show this help.
	@awk 'BEGIN {FS = ":.*##"; printf "Available targets:\n\n"} \
		/^[a-zA-Z0-9_.-]+:.*##/ { printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2 }' \
		$(MAKEFILE_LIST)

up: check-env tofu-init tofu-apply talos-config talos-bootstrap argocd-bootstrap upload-kubeconfig tofu-publish ## Full pipeline: VMs + Talos + ArgoCD + kubeconfig.
	@echo "==> Cluster ready. Run 'make argo-pwd' for the ArgoCD admin password."

down: check-env ## Destroy every resource OpenTofu manages (cluster wipe).
	tofu -chdir=$(TOFU_DIR) destroy -auto-approve

# ---------- OpenTofu ---------------------------------------------------------

check-env:
	@: $${PROXMOX_VE_ENDPOINT?missing PROXMOX_VE_ENDPOINT (check .env)}
	@: $${AWS_ACCESS_KEY_ID?missing AWS_ACCESS_KEY_ID (check .env)}
	@: $${MINIO_ENDPOINT?missing MINIO_ENDPOINT (check .env)}
	@: $${MINIO_STATE_BUCKET?missing MINIO_STATE_BUCKET (check .env)}
	@: $${MINIO_STATE_KEY?missing MINIO_STATE_KEY (check .env)}

tofu-init: check-env ## Initialise OpenTofu with the MinIO S3 backend.
	tofu -chdir=$(TOFU_DIR) init -reconfigure \
	  -backend-config="bucket=$(MINIO_STATE_BUCKET)" \
	  -backend-config="key=$(MINIO_STATE_KEY)" \
	  -backend-config="endpoints={s3=\"$(MINIO_ENDPOINT)\"}"

tofu-plan: check-env ## Show planned changes.
	tofu -chdir=$(TOFU_DIR) plan

tofu-apply: check-env ## Provision Proxmox VMs (target only the talos modules so the kubeconfig publish is skipped).
	tofu -chdir=$(TOFU_DIR) apply -auto-approve \
	  -target='proxmox_download_file.talos_iso' \
	  -target='module.talos_cp' \
	  -target='module.talos_wk'

tofu-publish: check-env ## Second apply: pushes kubeconfig to MinIO via aws_s3_object.
	tofu -chdir=$(TOFU_DIR) apply -auto-approve

# ---------- Talos / ArgoCD ---------------------------------------------------

talos-config: check-env ## Render machineconfigs and push them to every node.
	$(ROOT_DIR)/scripts/bootstrap.sh apply

talos-bootstrap: check-env ## Run talosctl bootstrap + fetch kubeconfig.
	$(ROOT_DIR)/scripts/bootstrap.sh bootstrap

argocd-bootstrap: check-env ## Install Cilium + ArgoCD, apply the App-of-Apps.
	$(ROOT_DIR)/scripts/bootstrap-argocd.sh

upload-kubeconfig: check-env ## Push kubeconfig to MinIO via the mc client.
	$(ROOT_DIR)/scripts/upload-kubeconfig.sh

gitops-render: check-env ## Substitute placeholders in gitops/ from .env (run once before the first `make up`).
	$(ROOT_DIR)/scripts/gitops-render.sh

# ---------- Operations -------------------------------------------------------

argo-pwd: ## Print the initial ArgoCD admin password.
	@KUBECONFIG=$(ROOT_DIR)/kubeconfig kubectl -n argocd get secret argocd-initial-admin-secret \
	  -o jsonpath='{.data.password}' | base64 -d; echo

status: ## Show cluster nodes and ArgoCD app status.
	@KUBECONFIG=$(ROOT_DIR)/kubeconfig kubectl get nodes -o wide || true
	@echo
	@KUBECONFIG=$(ROOT_DIR)/kubeconfig kubectl -n argocd get applications.argoproj.io || true

clean: ## Remove local generated files (does not touch MinIO state).
	rm -f $(ROOT_DIR)/kubeconfig $(ROOT_DIR)/talosconfig
	rm -f $(ROOT_DIR)/talos/talconfig.yaml \
	      $(ROOT_DIR)/talos/patches/controlplane.generated.yaml \
	      $(ROOT_DIR)/talos/patches/worker.generated.yaml
	rm -rf $(ROOT_DIR)/clusterconfig
