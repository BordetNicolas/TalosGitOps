# OpenBAO et Airflow sur le cluster `workflows` (cozy-01)

Exemple complet d'utilisation de l'application **OpenBAO** de Cozystack : Airflow (déployé dans le
cluster Kubernetes de tenant `workflows`) y lit tous ses secrets, sans qu'aucun ne soit dans Git.

## Schéma

```
 cluster de gestion (cozy-01)                         cluster de tenant "workflows"
 ┌───────────────────────────────────┐                ┌──────────────────────────────────────┐
 │ tenant-lab                        │                │ external-secrets (opérateur ESO)     │
 │  ├─ OpenBAO  openbao-lab  ◄───────┼── HTTP :8200 ──┼─ ClusterSecretStore "openbao"        │
 │  │    secret/airflow/app          │   (auth k8s)   │      │                               │
 │  │    secret/airflow/logs         │                │      ▼ ExternalSecret (ns airflow)   │
 │  ├─ Postgres  airflow  ◄──────────┼── :5432 ───────┼─ Secret airflow-credentials ─┐        │
 │  └─ Bucket    airflow-logs ◄──────┼── S3 ──────────┼─ Secret airflow-s3-logs ─────┤        │
 └───────────────────────────────────┘                │                              ▼        │
                                                      │ Airflow (api-server, scheduler, …)   │
                                                      └──────────────────────────────────────┘
```

| Brique | Rôle | Où |
|---|---|---|
| OpenBAO (`12-openbao.yaml`) | Coffre : stocke les secrets. Auto-descellement (`seal.type: static`). | `gitops-cozystack/tenants/lab/` |
| Postgres (`41-postgres-airflow.yaml`) | Base de métadonnées. Mot de passe généré par Cozystack. | idem |
| Bucket (`42-bucket-airflow-logs.yaml`) | Logs des tâches (remote logging). | idem |
| External Secrets Operator (`apps/18`) | Copie OpenBAO → Secrets Kubernetes. | cluster `workflows` |
| `ClusterSecretStore` + `ExternalSecret` | Dit à ESO où lire et quoi créer. | `gitops-cozystack/airflow-secrets/` |
| Airflow (`apps/20`, `airflow/values.yaml`) | Consomme les Secrets `airflow-credentials` et `airflow-s3-logs`. | cluster `workflows` |
| `scripts/cozystack-openbao.sh` | Initialise OpenBAO, configure l'auth Kubernetes, écrit les secrets. | `make cozystack-openbao` |

## Mise en route

```bash
# 1. DNS (airflow.lab.cozy-01.alexetnico.com)
make CLUSTER=cozy-01 unifi-plan && make CLUSTER=cozy-01 unifi-apply

# 2. Git
git push

# 3. Dès que Postgres, le Bucket et OpenBAO sont créés (le pod OpenBAO attend le Secret openbao-unseal,
#    créé par le script lui-même) :
make CLUSTER=cozy-01 cozystack-openbao
```

Le script est rejouable. Il crée `tenant-lab/openbao-unseal`, initialise OpenBAO (racine et clé de
récupération dans `clusters/cozy-01/openbao-init.json`, **gitignoré — à sauvegarder ailleurs**), active
KV v2 sur `secret/`, crée la politique `airflow-read` et l'authentification Kubernetes, puis écrit :

| Chemin OpenBAO | Clés |
|---|---|
| `secret/airflow/app` | `fernet-key`, `api-secret-key`, `jwt-secret`, `admin-password` (générés une fois), `connection` (reconstruite depuis le Secret Postgres) |
| `secret/airflow/logs` | variables `AIRFLOW__LOGGING__REMOTE_*` et connexion S3 `AIRFLOW_CONN_S3_LOGS` (depuis le Secret du Bucket) |

ArgoCD déploie ensuite, dans l'ordre : `external-secrets` (wave 5), `airflow-secrets` (6), `airflow` (7).

## Exemples d'utilisation

Dans les commandes ci-dessous, `bao` s'exécute dans le pod OpenBAO :

```bash
export KUBECONFIG=clusters/cozy-01/kubeconfig
TOKEN=$(jq -r .root_token clusters/cozy-01/openbao-init.json)
bao() { kubectl -n tenant-lab exec openbao-openbao-lab-0 -c openbao -- \
        env BAO_ADDR=http://127.0.0.1:8200 BAO_TOKEN="$TOKEN" bao "$@"; }

bao status                                   # initialisé ? descellé ?
bao kv list secret/airflow                   # app, logs
bao kv get secret/airflow/app                # lire (affiche les valeurs !)
bao kv get -field=admin-password secret/airflow/app   # mot de passe de l'interface Airflow (user admin)
bao kv metadata get secret/airflow/app       # versions : chaque écriture crée une version
```

**Écrire ou modifier un secret** : `bao kv patch secret/airflow/app admin-password=nouveau`. ESO
resynchronise le Secret Kubernetes sous 5 minutes (`refreshInterval`). Pour forcer :

```bash
kubectl --kubeconfig <kubeconfig-workflows> -n airflow annotate externalsecret airflow-credentials \
  force-sync=$(date +%s) --overwrite
```

Airflow ne relit pas ses secrets à chaud : redémarrez les pods concernés après un changement
(`kubectl -n airflow rollout restart deploy`). Ne changez pas `fernet-key` après le premier
démarrage : les connexions déjà chiffrées dans la base deviendraient illisibles.

**Ajouter un nouveau secret** pour une autre application : écrire sous `secret/<app>/…`, ajouter une
politique qui le permet et un rôle (`bao write auth/kubernetes/role/…`), puis un `ExternalSecret` :

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata: { name: mon-secret, namespace: mon-ns }
spec:
  secretStoreRef: { kind: ClusterSecretStore, name: openbao }
  target: { name: mon-secret }
  data:
    - secretKey: password          # clé du Secret Kubernetes
      remoteRef: { key: mon-app/db, property: password }   # chemin KV et champ
```

Le rôle actuel (`external-secrets`) n'a accès qu'à `secret/airflow/*` (politique `airflow-read`).

**Interface web d'OpenBAO** (connexion avec le root token) :

```bash
kubectl -n tenant-lab port-forward svc/openbao-openbao-lab-ui 8200:8200   # puis http://localhost:8200
```

## Points d'attention

- **Racine et clé de récupération** : perdre `openbao-init.json` fait perdre l'accès administrateur
  (les données restent, mais plus de root token). Générez un token d'exploitation et révoquez le root
  (`bao token create`, `bao token revoke`) une fois à l'aise.
- **Descellement statique** : la clé du coffre est dans le Secret `tenant-lab/openbao-unseal`, dans le
  même cluster que les données. Une sauvegarde d'etcd contient donc les deux. C'est le compromis choisi
  pour redémarrer sans intervention (voir la doc Cozystack sur `seal.type`).
- **Un seul réplica**, stockage `local` : un incident du nœud qui porte le volume rend OpenBAO
  indisponible. Les Secrets déjà copiés par ESO restent en place dans le cluster `workflows`.
- **Postgres** : le mot de passe est généré par Cozystack (`postgres-airflow-credentials`). Relancer
  `make cozystack-openbao` recopie le mot de passe courant dans `connection`.
- **Code custom** : le dépôt `AirflowCustom` est cloné une fois au démarrage de chaque pod (pas de
  volume partagé RWX sur ce cluster). Redémarrer un pod pour récupérer une nouvelle version.
