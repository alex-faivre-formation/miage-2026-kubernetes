# Kubernetes - MIAGE 2026

Support de travaux pratiques Kubernetes pour la formation MIAGE 2026.

## Table des matieres

- [Presentation](#presentation)
- [Prerequis](#prerequis)
- [Travaux Pratiques](#travaux-pratiques)
- [Architecture globale](#architecture-globale)
- [Tests et validation](#tests-et-validation)
- [Corrections et errata](#corrections-et-errata)
- [Structure du depot](#structure-du-depot)

## Presentation

Ce depot contient **10 travaux pratiques** progressifs couvrant l'ecosysteme Kubernetes, du deploiement d'un simple conteneur Nginx jusqu'a la gestion des secrets avec HashiCorp Vault. Chaque TP est autonome et dispose de son propre README detaille avec theorie, schemas d'architecture, commandes pas a pas, troubleshooting et QCM de revision.

**Derniere mise a jour** : 4 mars 2026

**Environnement de test** : minikube (macOS Darwin 25.3.0)

## Prerequis

- Un cluster Kubernetes fonctionnel (minikube recommande)
- `kubectl` installe et configure
- `helm` installe (TPs 07, 09, 10)
- `jq` installe (TP 10)

```bash
# Demarrer minikube
minikube start

# Verifier le cluster
kubectl cluster-info
kubectl get nodes
```

## Travaux Pratiques

| # | TP | Namespace | Concepts | Lien |
|---|-----|-----------|----------|------|
| 01 | [Nginx - Premier deploiement](TPs/01-nginx/) | `nginx` | Pod, Namespace, Service (LoadBalancer), Labels/Selectors, Resources | [README](TPs/01-nginx/README.md) |
| 02 | [PostgreSQL - Stockage et configuration](TPs/02-postgres/) | `postgres` | ConfigMap, Secret, PV/PVC, Deployment, Probes (liveness/readiness) | [README](TPs/02-postgres/README.md) |
| 03 | [Workloads avances](TPs/03-workloads/) | `workloads` | Job, CronJob, DaemonSet, StatefulSet, Init Container, Sidecar | [README](TPs/03-workloads/README.md) |
| 04 | [RBAC - Controle d'acces](TPs/04-rbac/) | `postgres` | ServiceAccount, Role, ClusterRole, RoleBinding | [README](TPs/04-rbac/README.md) |
| 05 | [Network Policies](TPs/05-network-policies/) | `postgres` | Default-deny, allow rules, Zero Trust, CNI | [README](TPs/05-network-policies/README.md) |
| 06 | [Resource Management](TPs/06-resource-management/) | `resource-mgmt` | ResourceQuota, LimitRange, HPA, Taints/Tolerations, Node Affinity | [README](TPs/06-resource-management/README.md) |
| 07 | [Helm - Packaging](TPs/07-helm/) | `postgres` | Chart Helm, templating Go, values, rollback, revisions | [README](TPs/07-helm/README.md) |
| 08 | [ArgoCD - GitOps](TPs/08-argocd/) | `argocd` | GitOps, Application CRD, sync automatique, self-heal, drift detection | [README](TPs/08-argocd/README.md) |
| 09 | [Ingress et Harbor](TPs/09-ingress/) | `ingress-nginx` | Ingress Controller NGINX, routage HTTP/HTTPS, Harbor registry | [README](TPs/09-ingress/README.md) |
| 10 | [Vault - Gestion des secrets](TPs/10-vault/) | `vault` | HashiCorp Vault, HA/Raft, Shamir's Secret Sharing, Unseal | [README](TPs/10-vault/README.md) |

## Architecture globale

```
Cluster Kubernetes (minikube)
+------------------------------------------------------------------------+
|                                                                        |
|  Namespace: nginx          Namespace: postgres                         |
|  +------------------+      +----------------------------------------+  |
|  | Pod nginx        |      | Deployment postgresdb                  |  |
|  | Service LB :80   |      | Service ClusterIP :5432                |  |
|  +------------------+      | ConfigMap + Secret + PV/PVC            |  |
|                            +----------------------------------------+  |
|                                                                        |
|  Namespace: workloads      Namespace: resource-mgmt                    |
|  +------------------+      +----------------------------------------+  |
|  | Job, CronJob     |      | ResourceQuota + LimitRange + HPA       |  |
|  | DaemonSet        |      +----------------------------------------+  |
|  | StatefulSet      |                                                  |
|  | Init + Sidecar   |      Namespace: argocd                          |
|  +------------------+      +----------------------------------------+  |
|                            | ArgoCD (GitOps)                         |  |
|                            | -> Synchronise TPs/02-postgres depuis   |  |
|                            |    Git vers le namespace postgres       |  |
|                            +----------------------------------------+  |
|                                                                        |
|  Namespace: ingress-nginx  Namespace: vault                            |
|  +------------------+      +----------------------------------------+  |
|  | Ingress NGINX    |      | Vault HA (3 replicas, Raft)            |  |
|  | Harbor (optionnel)|     | Shamir's Secret Sharing                |  |
|  +------------------+      +----------------------------------------+  |
+------------------------------------------------------------------------+
```

## Tests et validation

Tous les TPs ont ete testes et valides sur **minikube** le 4 mars 2026.

| TP | Status | Notes |
|----|--------|-------|
| 01 - Nginx | Deploye et teste | Pod Running, Service accessible via `minikube service` |
| 02 - PostgreSQL | Deploye et teste | `pg_isready` OK, connexion psql validee, probes fonctionnelles |
| 03 - Workloads | Deploye et teste | Job complete, CronJob schedule, DaemonSet sur tous les noeuds, StatefulSet ordonne |
| 04 - RBAC | Deploye et teste | `kubectl auth can-i` valide les permissions |
| 05 - Network Policies | Deploye et teste | Deny-all et allow rules fonctionnels |
| 06 - Resource Management | Deploye et teste | Quotas, LimitRange, HPA configures |
| 07 - Helm | Deploye et teste | `helm lint` OK, `helm template` OK, deploy/rollback fonctionnels |
| 08 - ArgoCD | Deploye et teste | Application Synced + Healthy, self-heal actif, drift detection OK |
| 09 - Ingress | Valide (dry-run) | Ingress Controller NGINX installe, manifests valides |
| 10 - Vault | Valide (template) | Helm template OK, configuration HA/Raft validee |

## Corrections et errata

Corrections appliquees par rapport au cours original :

| Probleme | Correction |
|----------|------------|
| `mountPath: /var/lib/postgresql/data` causait un CrashLoopBackOff avec PostgreSQL 18+ | Corrige en `mountPath: /var/lib/postgresql` -- l'image cree automatiquement le sous-repertoire `data` |
| `storageClassName: hostpath` introuvable sur minikube | Corrige en `storageClassName: standard` (StorageClass par defaut de minikube) |
| Conflit de noms dans le StatefulSet (meme nom que le Deployment du TP02) | Renomme en `postgresdb-sts` avec service headless `postgresdb-headless` |
| ArgoCD : 3 fichiers Deployment dans le meme dossier causaient une erreur "appeared 3 times" | Variantes deplacees dans `examples/` (ArgoCD ne recurse pas par defaut) |

## Structure du depot

```
miage-2026-kubernetes/
├── README.md                          # Ce fichier
└── TPs/
    ├── 01-nginx/                      # Deploiement Nginx basique
    │   ├── README.md
    │   ├── namespaces.yml
    │   ├── nginx.yml
    │   ├── service.yml
    │   ├── configMap.yml
    │   ├── secrets.yml
    │   ├── pv.yml
    │   ├── pvc.yml
    │   └── postgres.yml
    ├── 02-postgres/                   # PostgreSQL avec ConfigMap/Secret/PV
    │   ├── README.md
    │   ├── namespace.yaml
    │   ├── configmap.yaml
    │   ├── secret.yaml
    │   ├── pv.yaml
    │   ├── pvc.yaml
    │   ├── deployment.yaml
    │   ├── service.yaml
    │   └── examples/
    │       ├── deployment-with-secret.yaml
    │       └── deployment-secret-volume.yaml
    ├── 03-workloads/                  # Job, CronJob, DaemonSet, StatefulSet
    │   ├── README.md
    │   ├── job.yaml
    │   ├── cronjob.yaml
    │   ├── daemonset.yaml
    │   ├── statefulset.yaml
    │   ├── init-container.yaml
    │   └── sidecar.yaml
    ├── 04-rbac/                       # RBAC : Role, ClusterRole, Bindings
    │   ├── README.md
    │   ├── serviceaccount.yaml
    │   ├── role.yaml
    │   ├── rolebinding.yaml
    │   └── clusterrole.yaml
    ├── 05-network-policies/           # NetworkPolicy : deny + allow
    │   ├── README.md
    │   ├── default-deny-ingress.yaml
    │   └── allow-frontend-to-db.yaml
    ├── 06-resource-management/        # Quotas, Limits, HPA, Scheduling
    │   ├── README.md
    │   ├── resourcequota.yaml
    │   ├── limitrange.yaml
    │   ├── hpa.yaml
    │   ├── taints-tolerations.yaml
    │   └── node-affinity.yaml
    ├── 07-helm/                       # Chart Helm PostgreSQL
    │   ├── README.md
    │   ├── values-prod.yaml
    │   └── postgresdb/
    │       ├── Chart.yaml
    │       ├── values.yaml
    │       └── templates/
    │           ├── _helpers.tpl
    │           ├── deployment.yaml
    │           ├── service.yaml
    │           └── pvc.yaml
    ├── 08-argocd/                     # ArgoCD GitOps
    │   ├── README.md
    │   └── application.yaml
    ├── 09-ingress/                    # Ingress Controller + Harbor
    │   ├── README.md
    │   ├── ingress-example.yaml
    │   └── setup-ingress-nginx.sh
    └── 10-vault/                      # HashiCorp Vault HA
        ├── README.md
        ├── helm-vault-raft-values.yml
        ├── helm-vault-ha-values.yml
        └── setup.sh
```

## Liens utiles

- [Documentation Kubernetes](https://kubernetes.io/docs/)
- [minikube](https://minikube.sigs.k8s.io/)
- [Helm](https://helm.sh/)
- [ArgoCD](https://argo-cd.readthedocs.io/)
- [HashiCorp Vault](https://developer.hashicorp.com/vault)
