#!/usr/bin/env bash
# Initialise and configure the tenant OpenBAO (Cozystack app tenant-lab/openbao-lab) and fill it
# with the secrets of Airflow. Idempotent; secrets are never printed and never committed.
#
#   1. Secret tenant-lab/openbao-unseal   32-byte key of the static seal (auto-unseal)
#   2. bao operator init                  recovery key + root token -> clusters/<cluster>/openbao-init.json
#   3. KV v2 at secret/, policy airflow-read, Kubernetes auth method bound to the tenant cluster
#      "workflows" (role external-secrets, used by the External Secrets Operator)
#   4. secret/airflow/app   fernet-key, api-secret-key, jwt-secret, admin-password (generated once),
#                           connection (rebuilt from the Cozystack Postgres Secret)
#      secret/airflow/logs  remote logging env + S3 connection (from the Cozystack Bucket)
#
# Usage: cozystack-openbao.sh [cluster] [tenant-ns]   defaults: workflows, tenant-lab

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "${SCRIPT_DIR}/lib.sh"

require_cmd kubectl
require_cmd jq
require_cmd openssl

K8S_NAME="${1:-workflows}"
TENANT_NS="${2:-tenant-lab}"
BAO_NAME="openbao-lab"
POD="openbao-${BAO_NAME}-0"
INIT_FILE="${CLUSTER_DIR}/openbao-init.json"
PG_SECRET="postgres-airflow-credentials"
PG_SERVICE="postgres-airflow-rw.${TENANT_NS}.svc"
LOGS_SECRET="bucket-airflow-logs-airflow"
TENANT_API="https://kubernetes-${K8S_NAME}.${TENANT_NS}.svc:6443"

mgmt() { KUBECONFIG="${KUBECONFIG_PATH}" kubectl "$@"; }
bao_status() { mgmt -n "${TENANT_NS}" exec "${POD}" -c openbao -- env BAO_ADDR=http://127.0.0.1:8200 bao status -format=json 2>/dev/null || true; }
# bao <args>: runs inside the pod with the root token (token passed through the environment).
# bao_stdin is the same with the local stdin forwarded (policy files); plain bao never reads it.
bao() { mgmt -n "${TENANT_NS}" exec "${POD}" -c openbao -- env BAO_ADDR=http://127.0.0.1:8200 BAO_TOKEN="${ROOT_TOKEN}" bao "$@" </dev/null; }
bao_stdin() { mgmt -n "${TENANT_NS}" exec -i "${POD}" -c openbao -- env BAO_ADDR=http://127.0.0.1:8200 BAO_TOKEN="${ROOT_TOKEN}" bao "$@"; }
rand_hex() { openssl rand -hex "$1"; }

# --- 1. static seal key -----------------------------------------------------------------------
if ! mgmt -n "${TENANT_NS}" get secret openbao-unseal >/dev/null 2>&1; then
  mgmt -n "${TENANT_NS}" create secret generic openbao-unseal \
    --from-literal=key="$(head -c 32 /dev/urandom | base64 | tr -d '\n')"
  log "secret ${TENANT_NS}/openbao-unseal created (static seal key)"
fi

log "waiting for ${TENANT_NS}/${POD}"
for _ in $(seq 1 90); do
  [[ "$(mgmt -n "${TENANT_NS}" get pod "${POD}" -o jsonpath='{.status.phase}' 2>/dev/null)" == "Running" && -n "$(bao_status)" ]] && break
  sleep 10
done
status="$(bao_status)"
[[ -n "${status}" ]] || die "OpenBAO pod ${POD} is not responding — check 'kubectl -n ${TENANT_NS} get pods'"

# StatefulSet update strategy is OnDelete: a pod still running with the old (shamir) config must
# be replaced once the OpenBAO app asks for the static seal. Safe only while uninitialized.
want_seal="$(mgmt -n "${TENANT_NS}" get openbao "${BAO_NAME}" -o jsonpath='{.spec.seal.type}' 2>/dev/null || true)"
if [[ "${want_seal}" == "static" && "$(jq -r .type <<<"${status}")" != "static" ]]; then
  [[ "$(jq -r .initialized <<<"${status}")" == "false" ]] ||
    die "OpenBAO is already initialized with a shamir seal; migrating it to static is not automated (see seal.allowMigration in the Cozystack docs)"
  # The StatefulSet template may not carry the new seal yet (HelmRelease still reconciling): retry.
  for attempt in 1 2 3 4; do
    log "replacing the pod so that it starts with the static seal (attempt ${attempt})"
    mgmt -n "${TENANT_NS}" delete pod "${POD}" --wait=true >/dev/null
    for _ in $(seq 1 18); do
      sleep 10
      status="$(bao_status)"
      [[ -n "${status}" && "$(jq -r .type <<<"${status}")" == "static" ]] && break 2
    done
  done
  [[ "$(jq -r .type <<<"${status}")" == "static" ]] || die "pod did not come back with the static seal — check 'kubectl -n ${TENANT_NS} get hr | grep openbao'"
fi

# --- 2. init ----------------------------------------------------------------------------------
if [[ "$(jq -r .initialized <<<"${status}")" == "false" ]]; then
  log "initialising OpenBAO"
  if [[ "$(jq -r .type <<<"${status}")" == "static" ]]; then
    init_args=(-recovery-shares=1 -recovery-threshold=1)
  else
    init_args=(-key-shares=1 -key-threshold=1)
  fi
  umask 077
  mgmt -n "${TENANT_NS}" exec "${POD}" -c openbao -- env BAO_ADDR=http://127.0.0.1:8200 \
    bao operator init -format=json "${init_args[@]}" > "${INIT_FILE}"
  chmod 600 "${INIT_FILE}"
  log "root token and keys saved to ${INIT_FILE} (gitignored) — keep a copy somewhere safe"
  if [[ "$(jq -r .type <<<"${status}")" != "static" ]]; then
    mgmt -n "${TENANT_NS}" exec "${POD}" -c openbao -- env BAO_ADDR=http://127.0.0.1:8200 \
      bao operator unseal "$(jq -r '.unseal_keys_b64[0]' "${INIT_FILE}")" >/dev/null
  fi
fi
[[ -s "${INIT_FILE}" ]] || die "OpenBAO is initialized but ${INIT_FILE} is missing: the root token is not available here"
ROOT_TOKEN="$(jq -r .root_token "${INIT_FILE}")"

for _ in $(seq 1 30); do
  [[ "$(jq -r .sealed <<<"$(bao_status)")" == "false" ]] && break
  sleep 5
done
[[ "$(jq -r .sealed <<<"$(bao_status)")" == "false" ]] || die "OpenBAO is still sealed"
log "OpenBAO is initialised and unsealed"

# --- 3. engine, policy, Kubernetes auth -------------------------------------------------------
bao secrets list -format=json | jq -e 'has("secret/")' >/dev/null || bao secrets enable -path=secret kv-v2 >/dev/null
bao_stdin policy write airflow-read - >/dev/null <<'POLICY'
path "secret/data/airflow/*"     { capabilities = ["read"] }
path "secret/metadata/airflow/*" { capabilities = ["read", "list"] }
POLICY

tenant_kc="$(mktemp)"
trap 'rm -f "${tenant_kc}"' EXIT
mgmt -n "${TENANT_NS}" get secret "kubernetes-${K8S_NAME}-admin-kubeconfig" -o jsonpath='{.data.admin\.conf}' | base64 -d > "${tenant_kc}"
[[ -s "${tenant_kc}" ]] || die "kubeconfig of cluster ${K8S_NAME} not found in ${TENANT_NS}"
tk() { KUBECONFIG="${tenant_kc}" kubectl "$@"; }

# Reviewer ServiceAccount in the tenant cluster: lets OpenBAO call TokenReview on its API.
tk apply -f - >/dev/null <<'YAML'
apiVersion: v1
kind: ServiceAccount
metadata: { name: openbao-token-reviewer, namespace: kube-system }
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata: { name: openbao-token-reviewer }
roleRef: { apiGroup: rbac.authorization.k8s.io, kind: ClusterRole, name: system:auth-delegator }
subjects: [{ kind: ServiceAccount, name: openbao-token-reviewer, namespace: kube-system }]
---
apiVersion: v1
kind: Secret
metadata:
  name: openbao-token-reviewer
  namespace: kube-system
  annotations: { kubernetes.io/service-account.name: openbao-token-reviewer }
type: kubernetes.io/service-account-token
YAML
reviewer_jwt=""
for _ in $(seq 1 30); do
  reviewer_jwt="$(tk -n kube-system get secret openbao-token-reviewer -o jsonpath='{.data.token}' | base64 -d)"
  [[ -n "${reviewer_jwt}" ]] && break
  sleep 2
done
[[ -n "${reviewer_jwt}" ]] || die "no token for openbao-token-reviewer in ${K8S_NAME}"
tenant_ca="$(tk -n kube-system get secret openbao-token-reviewer -o jsonpath='{.data.ca\.crt}' | base64 -d)"

bao auth list -format=json | jq -e 'has("kubernetes/")' >/dev/null || bao auth enable kubernetes >/dev/null
bao write auth/kubernetes/config \
  kubernetes_host="${TENANT_API}" \
  kubernetes_ca_cert="${tenant_ca}" \
  token_reviewer_jwt="${reviewer_jwt}" \
  disable_iss_validation=true >/dev/null
bao write auth/kubernetes/role/external-secrets \
  bound_service_account_names=external-secrets \
  bound_service_account_namespaces=external-secrets \
  policies=airflow-read ttl=1h >/dev/null
log "KV v2 'secret/', policy airflow-read and Kubernetes auth (role external-secrets) configured"

# --- 4. Airflow secrets -----------------------------------------------------------------------
log "waiting for ${TENANT_NS}/${PG_SECRET} and ${TENANT_NS}/${LOGS_SECRET} (Cozystack Postgres and Bucket)"
for _ in $(seq 1 60); do
  mgmt -n "${TENANT_NS}" get secret "${PG_SECRET}" >/dev/null 2>&1 &&
    mgmt -n "${TENANT_NS}" get secret "${LOGS_SECRET}" >/dev/null 2>&1 && break
  sleep 10
done
mgmt -n "${TENANT_NS}" get secret "${PG_SECRET}" >/dev/null 2>&1 || die "secret ${PG_SECRET} not found — is Postgres 'airflow' deployed (tenants/lab/41-postgres-airflow.yaml)?"
mgmt -n "${TENANT_NS}" get secret "${LOGS_SECRET}" >/dev/null 2>&1 || die "secret ${LOGS_SECRET} not found — is Bucket 'airflow-logs' deployed (tenants/lab/42-bucket-airflow-logs.yaml)?"

pg_password="$(mgmt -n "${TENANT_NS}" get secret "${PG_SECRET}" -o json | jq -r '.data.airflow // empty' | base64 -d)"
[[ -n "${pg_password}" ]] ||
  die "no key 'airflow' in ${PG_SECRET} (keys: $(mgmt -n "${TENANT_NS}" get secret "${PG_SECRET}" -o json | jq -r '.data|keys|join(",")'))"
pg_password_uri="$(jq -rn --arg p "${pg_password}" '$p|@uri')"
connection="postgresql+psycopg2://airflow:${pg_password_uri}@${PG_SERVICE}:5432/airflow?sslmode=prefer"

if bao kv get -format=json secret/airflow/app >/dev/null 2>&1; then
  bao kv patch secret/airflow/app connection="${connection}" >/dev/null
  log "secret/airflow/app already exists: generated keys kept, connection refreshed"
else
  fernet="$(head -c 32 /dev/urandom | base64 | tr '+/' '-_' | tr -d '\n')"
  bao kv put secret/airflow/app \
    fernet-key="${fernet}" \
    api-secret-key="$(rand_hex 32)" \
    jwt-secret="$(rand_hex 64)" \
    admin-password="$(rand_hex 12)" \
    connection="${connection}" >/dev/null
  log "secret/airflow/app created (fernet-key, api-secret-key, jwt-secret, admin-password, connection)"
fi

info="$(mgmt -n "${TENANT_NS}" get secret "${LOGS_SECRET}" -o jsonpath='{.data.BucketInfo}' | base64 -d)"
endpoint="$(jq -r '.spec.secretS3.endpoint' <<<"${info}")"
bucket_name="$(jq -r '.spec.bucketName' <<<"${info}")"
access_key="$(jq -r '.spec.secretS3.accessKeyID' <<<"${info}")"
secret_key="$(jq -r '.spec.secretS3.accessSecretKey' <<<"${info}")"
[[ -n "${bucket_name}" && "${endpoint}" != null && "${access_key}" != null ]] || die "incomplete BucketInfo in ${LOGS_SECRET}"
conn_json="$(jq -nc --arg ak "${access_key}" --arg sk "${secret_key}" --arg ep "${endpoint}" \
  '{conn_type:"aws", login:$ak, password:$sk, extra:{endpoint_url:$ep, region_name:"us-east-1", config_kwargs:{s3:{addressing_style:"path"}}}}')"
bao kv put secret/airflow/logs \
  AIRFLOW__LOGGING__REMOTE_LOGGING=True \
  AIRFLOW__LOGGING__REMOTE_BASE_LOG_FOLDER="s3://${bucket_name}/logs" \
  AIRFLOW__LOGGING__REMOTE_LOG_CONN_ID=s3_logs \
  AIRFLOW_CONN_S3_LOGS="${conn_json}" >/dev/null
log "secret/airflow/logs written (bucket ${bucket_name} @ ${endpoint#*://})"

log "done. Read a value:  kubectl -n ${TENANT_NS} exec ${POD} -- env BAO_ADDR=http://127.0.0.1:8200 BAO_TOKEN=\$(jq -r .root_token ${INIT_FILE}) bao kv get secret/airflow/app"
