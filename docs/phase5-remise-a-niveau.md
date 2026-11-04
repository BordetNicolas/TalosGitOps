# Phase 5 — Remise à niveau (talos-02)

Relevé effectué le 2026-11-04 sur le cluster `talos-02` (MCP Kubernetes / Grafana, dépôts GitHub upstream).

## 0. État des lieux

Cluster : **Kubernetes 1.36.1**, **Talos 1.13.0**, 3 control-planes + 5 workers.

| Composant | Déployé | Dernière version | Compatibilité Kubernetes 1.36 | Écart |
|---|---|---|---|---|
| Cilium | 1.16.4 | 1.20.4 | 1.16 testé sur 1.27–1.30 ; **1.20 testé sur 1.33–1.36** | 4 versions mineures, **hors support** |
| Longhorn | 1.7.2 | 1.13.0 | 1.13 exige Kubernetes ≥ 1.34 | 6 versions mineures |
| ArgoCD | v3.1.0 (chart 8.3.0) | v3.6.1 (chart 10.12.1) | 3.5 : 1.33–1.36 ; 3.6 : 1.34–1.37 | 5 versions mineures |
| kube-prometheus-stack | 67.11.0 (Grafana 11.4.0) | 92.18.0 | chart ≥ 1.25 | 25 versions majeures |
| ingress-nginx | 4.11.3 (contrôleur v1.11.3) | 4.15.1 / v1.15.1 (**projet retiré en mars 2026**) | — | **vulnérable à CVE-2025-1974** |
| metrics-server | absent | chart 3.14.0 (v0.9.0) | — | `metrics.k8s.io` indisponible |
| Alloy | chart 1.8.1 (v1.16.1) | v1.21.3 | — | hors périmètre (mise à jour possible plus tard) |

### Constats annexes (bloquants ou à traiter dans cette phase)

1. **Logs ingérés en 5 exemplaires.** Chaque pod du DaemonSet Alloy (5 workers) collecte les logs de *tous* les pods du cluster. Mesure : Loki reçoit environ 123 lignes/s mais n'en stocke qu'environ 30 lignes/s après déduplication. Corrigé au point 15.
2. **ingress-nginx v1.11.3 est vulnérable à IngressNightmare** (CVE-2025-1974, CVSS 9.8, corrigé à partir de v1.11.5/v1.12.1), avec `allow-snippet-annotations: "true"` alors qu'aucun snippet n'est utilisé. → Correctif immédiat (§16.0).
3. **`ignoreDifferences` combiné à `RespectIgnoreDifferences=true` gèle des champs pendant le sync** :
   - Cilium : `/spec/template/spec/initContainers` du DaemonSet. Les init containers (dont `install-cni-binaries`) garderaient l'image 1.16.4.
   - Longhorn : `.spec` complet des CRD. Les schémas resteraient ceux de la 1.7.2.
   → Ces règles doivent être resserrées **avant** toute montée de version (§16.1 et §16.2).
4. **Inline manifest Cilium dans Talos** : `talosctl upgrade-k8s` réapplique les inline manifests. Après chaque montée de version de Cilium dans ArgoCD, il faut aligner `CILIUM_CHART_VERSION`, `bootstrap/cilium-values.yaml` et `scripts/bootstrap.sh` (valeur par défaut), puis lancer `make talos-config`. Sinon, le prochain `upgrade-k8s` **redescend** Cilium à l'ancienne version.
5. **Grafana sans persistance** (`storage: emptyDir`) : tout ce qui est créé dans l'interface, y compris le compte de service et le token de `mcp-grafana`, disparaît à chaque redémarrage du pod. Or chaque montée de version de kube-prometheus-stack le redémarre. → Prérequis du §16.4.
6. Pour information : l'interface Longhorn est publiée dans le DNS Cloudflare (IP privée MetalLB) sans authentification.

## Ordre d'exécution

| Lot | Contenu | Risque | Retour arrière |
|---|---|---|---|
| 5.0 | ingress-nginx 4.15.1 + snippets désactivés | faible | revert Git |
| 5.1 | metrics-server (point 14) | moyen (certificats du kubelet) | revert Git + patch Talos |
| 5.2 | Étiquettes Alloy et fin des doublons (point 15) | faible | revert Git |
| 5.3 | Cilium 1.16 → 1.20 | **élevé** (CNI) | une version mineure en arrière |
| 5.4 | Longhorn 1.7 → 1.13 | **élevé** (données) | **aucun** (retour arrière interdit) → sauvegardes |
| 5.5 | ArgoCD 3.1 → 3.5 (puis 3.6) | moyen | `make argocd-bootstrap` |
| 5.6 | kube-prometheus-stack 67 → 92 | moyen | revert Git (les CRD restent) |
| 5.7 | ingress-nginx → Envoy Gateway (Gateway API) | moyen | annotations DNS remises sur les Ingress |

Règles communes à chaque étape :

- **Une étape = un commit = un sync.** Ne passer à la suivante que si toutes les applications sont `Synced/Healthy`, qu'aucun pod n'est en CrashLoop et que les URL (ArgoCD, Grafana, Longhorn, MCP) répondent.
- Avant les lots 5.3 et 5.4 : snapshot etcd (`talosctl -n <cp> etcd snapshot etcd-$(date +%F).db`) et dernier `backup-daily` Longhorn `Completed` pour tous les volumes du groupe `backup`.
- Prévisualiser avec `argocd app diff <app>` (ou `helm template … | kubectl diff -f -`) avant de pousser.
- Modifier les modèles `gitops/`, puis lancer `make CLUSTER=talos-02 gitops-render` et committer les deux arborescences.

---

## 14. metrics-server

Option retenue : **rotation des certificats serveur du kubelet** (option recommandée par la documentation Talos), et non `--kubelet-insecure-tls`.

> ⚠️ Ordre impératif : l'approbateur de CSR doit tourner **avant** l'activation de `serverTLSBootstrap`. Sinon les CSR du kubelet restent en attente, puis `kubectl logs/exec` échouent, et avec eux la collecte des logs par Alloy, qui passe par l'API de logs.

**Étape 1 — kubelet-serving-cert-approver (v0.12.1)** : `gitops/apps/26-kubelet-serving-cert-approver.yaml`

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: kubelet-serving-cert-approver
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "1"
spec:
  project: platform
  source:
    repoURL: https://github.com/alex1989hu/kubelet-serving-cert-approver
    targetRevision: v0.12.1
    path: deploy
    directory:
      include: standalone-install.yaml
  destination:
    server: https://kubernetes.default.svc
    namespace: kubelet-serving-cert-approver
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

Ajouter `https://github.com/alex1989hu/kubelet-serving-cert-approver` dans `sourceRepos` de `gitops/projects/platform.yaml`. Le manifeste crée son propre namespace (PSS `restricted`).

**Étape 2 — Talos** (`talos/patches/cluster-common-base.yaml`, syntaxe Talos ≤ 1.13) :

```yaml
machine:
  kubelet:
    extraConfig:
      shutdownGracePeriod: 30s
      shutdownGracePeriodCriticalPods: 10s
      serverTLSBootstrap: true
```

Lancer `make CLUSTER=talos-02 talos-config` (redémarrage du kubelet, sans reboot), puis `kubectl get csr` : tous les CSR `kubernetes.io/kubelet-serving` doivent être `Approved,Issued`.

**Étape 3 — metrics-server (chart 3.14.0)** : `gitops/apps/37-metrics-server.yaml`

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: metrics-server
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "7"
spec:
  project: platform
  source:
    repoURL: https://kubernetes-sigs.github.io/metrics-server/
    chart: metrics-server
    targetRevision: 3.14.0
    helm:
      releaseName: metrics-server
      values: |
        replicas: 2
        podDisruptionBudget:
          enabled: true
          minAvailable: 1
        resources:
          requests:
            cpu: 50m
            memory: 64Mi
          limits:
            memory: 128Mi
        metrics:
          enabled: true
        serviceMonitor:
          enabled: true
          additionalLabels:
            release: kube-prometheus-stack
  destination:
    server: https://kubernetes.default.svc
    namespace: kube-system
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - ServerSideApply=true
```

Ajouter `https://kubernetes-sigs.github.io/metrics-server/` dans `sourceRepos`. La vague 7 (après kube-prometheus-stack) garantit que le CRD `ServiceMonitor` existe déjà lors d'une reconstruction du cluster.

**Validation** : `kubectl get apiservice v1beta1.metrics.k8s.io` → `Available=True` ; `kubectl top nodes` ; outil MCP `nodes_top`. Les ServiceMonitor kubelet de kube-prometheus-stack ne sont pas affectés.

**Documentation** : tableau des vagues dans `CLAUDE.md`, section *Troubleshooting* (CSR en attente).

---

## 15. Alloy : étiquettes `namespace`, `pod` et `container`

Dans le même changement, on active le **clustering** d'Alloy : les cibles sont réparties entre les 5 pods au lieu d'être collectées 5 fois. Cette solution ne demande pas de tolérance control-plane, car `loki.source.kubernetes` lit les logs via l'API, quel que soit le nœud.

Dans `gitops/apps/34-alloy.yaml` :

```alloy
discovery.kubernetes "pods" {
  role = "pod"
}

discovery.relabel "pods" {
  targets = discovery.kubernetes.pods.targets

  rule {
    source_labels = ["__meta_kubernetes_namespace"]
    target_label  = "namespace"
  }
  rule {
    source_labels = ["__meta_kubernetes_pod_name"]
    target_label  = "pod"
  }
  rule {
    source_labels = ["__meta_kubernetes_pod_container_name"]
    target_label  = "container"
  }
}

loki.source.kubernetes "pods" {
  targets    = discovery.relabel.pods.output
  forward_to = [loki.process.pods.receiver]

  clustering {
    enabled = true
  }
}
```

Valeurs du chart (au même niveau que `configMap`) :

```yaml
alloy:
  clustering:
    enabled: true
```

Notes :

- **Cardinalité inchangée** : l'étiquette `instance` (`ns/pod:container`) a déjà la même cardinalité. Les requêtes existantes sur `instance` continuent de fonctionner.
- `service_name` sera dérivé de `container` au lieu de valoir `loki.source.kubernetes.pods` partout. C'est un gain de lisibilité dans Explore/Drilldown.

**Validation** :

- `list_loki_label_names` contient `namespace`, `pod` et `container`.
- `sum(rate(loki_distributor_lines_received_total[10m]))` passe d'environ 123/s à environ 30/s, avec un volume stocké inchangé.
- L'interface Alloy (port 12345, page *Clustering*) affiche 5 pairs.

---

## 16. Feuille de route des mises à jour

### 16.0 Correctif immédiat d'ingress-nginx (avant la migration)

`gitops/apps/20-ingress-nginx.yaml` : `targetRevision: 4.15.1` (dernière version, contrôleur v1.15.1) et `allowSnippetAnnotations: false`.

Depuis la 1.12, le contrôleur applique `annotations-risk-level` ; les annotations utilisées (`auth-*`, `proxy-*`, `backend-protocol`, `ssl-redirect`) restent autorisées.

**Validation** : connexion à toutes les URL, basic auth MCP, sessions SSE longues côté MCP.

### 16.1 Cilium : 1.16.4 → 1.16.19 → 1.17.18 → 1.18.16 → 1.19.10 → 1.20.4

Seul chemin testé par Cilium : une version mineure à la fois, en passant d'abord par le dernier correctif de la version mineure courante.

**Prérequis (commit à part)** : supprimer l'`ignoreDifferences` sur `initContainers` dans `00-cilium.yaml` et vérifier avec `argocd app diff cilium` que le diff est vide ou sans conséquence. Sinon, les init containers ne suivent pas les montées de version.

**À chaque étape** :

1. Mettre à jour `targetRevision` dans `gitops/apps/00-cilium.yaml`, plus les valeurs si nécessaire.
2. Reporter ces valeurs dans `bootstrap/cilium-values.yaml`, `CILIUM_CHART_VERSION` (`cluster.env`, `cluster.env.example`) et la valeur par défaut de `scripts/bootstrap.sh`.
3. `gitops-render`, commit, sync. Le déploiement se fait nœud par nœud (`maxUnavailable: 1`, agent et Envoy).
4. `make CLUSTER=talos-02 talos-config` pour réaligner l'inline manifest (voir constat 4).
5. Valider : `cilium status --wait`, `cilium connectivity test` (facultatif, crée un namespace de test), Hubble relay, URL d'entrée, résolution DNS des pods.

| Étape | Points d'attention |
|---|---|
| → 1.17 | La sonde liveness ne vérifie plus l'apiserver. Rien d'autre ne concerne cette configuration. |
| → 1.18 | Le label `io.cilium.k8s.policy.serviceaccount` entre dans les identités : hausse temporaire du nombre d'identités. |
| → 1.19 | **Le Job certgen (CronJob Hubble) n'est plus un hook Helm** : retirer `certgen.annotations.job` (`hook-delete-policy`, commit deeeb08) et prévoir la gestion du Job immuable (`Replace=true` ciblé ou `ttlSecondsAfterFinished`). L'authentification mesh est désactivée par défaut (non utilisée ici). |
| → 1.20 | CNI spec 1.0.0 par défaut. certgen vérifie la validité de la chaîne d'autorité de certification. Nouvelle option `configDriftDetection`. Gateway API ≥ v1.6.1 si le Gateway Cilium est utilisé. |

**Retour arrière** : uniquement vers la version mineure précédente (revert Git + `talos-config`).

### 16.2 Longhorn : 1.7.2 → 1.7.x (dernier correctif) → 1.8.2 → 1.9.2 → 1.10.2 → 1.11.3 → 1.12.1 → 1.13.0

Longhorn refuse de sauter une version mineure et interdit tout retour arrière.

**Prérequis (commit à part)** :

- Remplacer `ignoreDifferences` sur CRD `.spec` par une règle limitée à ce que longhorn-manager modifie réellement : `.spec.conversion.webhook.clientConfig.caBundle`, à confirmer avec `argocd app diff longhorn`. Sinon les schémas restent ceux de la 1.7.2.
- Activer la montée de version automatique des moteurs : `defaultSettings.concurrentAutomaticEngineUpgradePerNodeLimit: 1`. Chaque volume doit être passé sur la nouvelle image moteur avant la version mineure suivante.

**À chaque étape** :

- Vérifier avant : tous les volumes `healthy`, aucune reconstruction en cours, dernière sauvegarde `Completed`.
- Changer `targetRevision`, synchroniser, puis attendre `longhorn-manager` et l'instance-manager.
- Vérifier que tous les volumes sont sur la nouvelle image moteur et supprimer les anciennes `EngineImage`.

| Étape | Points d'attention |
|---|---|
| → 1.8 | Kubernetes ≥ 1.25, external-snapshotter v8.2. |
| → 1.9 | `v1beta1` n'est plus servi ; suppression des champs obsolètes en `v1beta2` ; `environment_check.sh` supprimé (utiliser `longhornctl`). |
| → 1.10 | **`v1beta1` supprimé** : tous les CRD doivent avoir `storedVersions == ["v1beta2"]` (déjà vrai pour `volumes.longhorn.io`, installé en 1.7). Vérifier tous les CRD avec `kubectl get crd -l app.kubernetes.io/name=longhorn -o json \| jq -r '.items[] \| [.metadata.name, (.status.storedVersions\|join(","))] \| @tsv'`. |
| → 1.11 / 1.12 | Concerne uniquement les backing images V2 (non utilisées, moteur V1). |
| → 1.13 | Kubernetes ≥ 1.34 ✓. Compte de service CSI dédié. **Network policies internes** : relire les *Important Notes* (interaction avec Cilium). |

### 16.3 ArgoCD : 3.1.0 → 3.1.x → 3.2.x → 3.3.x → 3.4.x → 3.5.x (→ 3.6.x une fois stabilisée)

| ArgoCD | Chart (indicatif, à confirmer via `helm search repo argo/argo-cd --versions`) |
|---|---|
| 3.1.9 | 9.0.5 |
| 3.2.x | 9.1.x – 9.3.x |
| 3.3.x | 9.4.x – 9.5.3 |
| 3.4.x | 9.5.12 – 10.1.x |
| 3.5.7 | 10.11.7 |
| 3.6.x | 10.12.x |

À chaque étape, mettre à jour `05-argocd.yaml`, `ARGOCD_CHART_VERSION` (`cluster.env`, `cluster.env.example`) et la valeur par défaut de `scripts/bootstrap-argocd.sh`. ArgoCD se met à jour lui-même ; s'il ne redémarre pas, `make CLUSTER=talos-02 argocd-bootstrap`.

| Étape | Points d'attention |
|---|---|
| chart 9.0.0 | `configs.params` retiré des valeurs par défaut (notre `server.insecure` reste valide) ; `applicationsetcontroller.policy` passe de `sync` à `""`. |
| → 3.2 | Nouveaux contrôles de santé (CronJob, utile pour le certgen Cilium). |
| → 3.3 | Le CRD ApplicationSet dépasse la taille autorisée en client-side apply (SSA déjà actif ✓). Helm 3.19. |
| → 3.4 | Format de la version de cluster modifié ; recherches DNS gRPC désactivées par défaut. |
| chart 10.0.0 | **`global.networkPolicy.create: true` par défaut** : vérifier ingress → argocd-server, MCP ArgoCD → argocd-server et le scraping Prometheus, ou forcer `false`. |
| → 3.5 | **Helm 4.2 dans repo-server** : relancer `argocd app diff` sur toutes les applications après la montée de version. GnuPG remplacé par Source Integrity. |
| → 3.6 | SSA utilise le diff côté serveur : revoir les `ignoreDifferences`. |

### 16.4 kube-prometheus-stack : 67.11.0 → 92.18.0

**Prérequis** : persistance Grafana, par exemple :

```yaml
grafana:
  persistence:
    enabled: true
    storageClassName: longhorn
    size: 2Gi
```

Ajouter les étiquettes `recurring-job*` du groupe `backup`, puis recréer le compte de service `mcp-grafana`. Sinon, le token MCP est perdu à chaque étape.

Les CRD sont appliqués par ArgoCD (SSA activé ✓). Procéder par paliers, avec validation à chaque palier :

| Palier | Changements notables |
|---|---|
| 67 → 72 | 68 : suppression de métriques (cardinalité apiserver) ; Prometheus-Operator jusqu'à 0.82. |
| 72 → 78 | 72 : `podDisruptionBudget.enabled` ; 73 : suppression des PSP et des anciennes API Ingress ; 75 : renommage des `additionalPrometheusRules`. |
| 78 → 83 | 79 : plus de mot de passe admin Grafana par défaut (`existingSecret` déjà utilisé ✓). |
| 83 → 89 | **84 : Grafana 13** (depuis 11.4 : plugins Angular supprimés depuis Grafana 12, vérifier les tableaux de bord) ; 85 : images distroless ; 89 : chart Grafana v13. |
| 89 → 92 | **90 : les ServiceMonitor du control plane ne lisent plus les identifiants sur le disque** (vérifier kubelet, apiserver et coredns) ; 91 : RBAC de l'opérateur resserré ; 92 : `nodeSelector` linux. |

**Validation à chaque palier** :

- `count(up == 0)` doit rester stable.
- Les alertes `Watchdog` arrivent.
- Les sources de données Loki/Tempo répondent.
- Les tableaux de bord par défaut s'affichent.
- `mcp-grafana` fonctionne.

### 16.5 Migration ingress-nginx → Envoy Gateway (Gateway API)

| Option | Avantages | Inconvénients |
|---|---|---|
| **Envoy Gateway 1.9** (recommandé) | Gateway API conforme (v1.6.1 embarquée) ; Kubernetes 1.33–1.36 ; `SecurityPolicy` basic auth ; politiques de timeout ; indépendant du CNI | Composant supplémentaire ; v1.9 en fin de vie le 2027-02-14 (suivre les versions mineures) |
| Gateway Cilium | Rien à installer (Envoy est déjà présent) | **Pas de basic auth** (MCP) ; couple les mises à jour de l'ingress à celles du CNI ; exige Cilium 1.20 |
| Traefik 3.7 | Fournisseur de compatibilité avec les annotations NGINX (transition rapide) ; basic auth bcrypt | Garde en pratique des objets Ingress au lieu de Gateway API |

**Plan (Envoy Gateway)** :

1. Application `envoy-gateway` (chart OCI `oci://docker.io/envoyproxy/gateway-helm`, v1.9.x, qui installe les CRD Gateway API). Ajouter le dépôt dans `sourceRepos` et dans `configs.repositories` d'ArgoCD.
2. Application `gateway` :
   - `GatewayClass` ;
   - `EnvoyProxy`, avec un Service LoadBalancer sur une **2ᵉ IP du pool MetalLB** et `externalTrafficPolicy: Local` ;
   - `Gateway` avec un listener HTTP:80 (redirection HTTPS) et un listener HTTPS:443 ;
   - `Certificate` wildcard `*.alexetnico.com` (DNS-01 Cloudflare, `letsencrypt-prod`). Tous les hôtes sont à un seul niveau, donc un seul certificat suffit.
3. Une `HTTPRoute` par service :
   - ArgoCD (CLI : `--grpc-web`), Grafana, Longhorn, Argo Workflows ;
   - MCP ×3 : `SecurityPolicy` basicAuth et timeouts 3600 s (`HTTPRoute.timeouts` / `BackendTrafficPolicy`). **Envoy Gateway n'accepte que les hachages SHA** : régénérer `MCP_BASIC_AUTH` dans Doppler avec `htpasswd -nbs`, clé de Secret `.htpasswd`.
   - Dépôt workloads : airflow, whoami.
4. external-dns (deux instances) : ajouter la source `gateway-httproute` ; l'annotation `external-dns.alpha.kubernetes.io/set` est portée par la `HTTPRoute`.
5. Bascule service par service, dans un seul commit : retirer l'annotation `set` de l'Ingress et l'ajouter sur la HTTPRoute. Tester avant avec `curl --resolve <host>:443:<IP2>`.
6. Une fois tous les services basculés : supprimer `20-ingress-nginx` et les Ingress. Nettoyer `sourceRepos`, `gitops-render.sh` (`METALLB_VIP`), `README.md` et `CLAUDE.md`.

**Retour arrière** : tant que l'étape 6 n'est pas faite, il suffit de remettre l'annotation DNS sur l'Ingress.

---

## Hors périmètre / à planifier ensuite

- Talos 1.13.0 → 1.13.2 (version attendue dans `terraform.tfvars.example`) et passage à la nouvelle syntaxe `KubeletConfig` quand Talos 1.14 sera visé.
- Mises à jour mineures : Alloy (1.8.1 → actuelle), Loki, Tempo, cert-manager, external-dns, MetalLB, Doppler operator, Argo Workflows.
- Authentification devant l'interface Longhorn (`SecurityPolicy` OIDC/basic auth une fois sur Envoy Gateway).
