# TP08 - ArgoCD — GitOps dans le cluster

## Objectifs
- Installer ArgoCD dans le cluster
- Créer une Application ArgoCD pour synchroniser des manifests depuis Git
- Observer la détection de dérive et le self-healing
- Comprendre le workflow GitOps

## Prérequis
- Cluster Kubernetes fonctionnel
- `kubectl` configuré
- Un dépôt Git contenant les manifests Kubernetes (ex: le dossier `02-postgres/`)

## Fichiers

| Fichier | Description |
|---------|-------------|
| `application.yaml` | CRD Application ArgoCD pour déployer la stack PostgreSQL depuis Git |

## Installation d'ArgoCD

### 1. Installer ArgoCD
```bash
kubectl create namespace argocd

kubectl apply -n argocd \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# Attendre que tous les pods soient prêts
kubectl wait --for=condition=Ready pods --all -n argocd --timeout=180s
kubectl get pods -n argocd
```

### 2. Accéder à l'interface web
```bash
# Port-forward vers le serveur ArgoCD
kubectl port-forward svc/argocd-server 8080:443 -n argocd
```

Ouvrir : **https://localhost:8080**

```bash
# Récupérer le mot de passe admin
kubectl get secret argocd-initial-admin-secret \
  -n argocd \
  -o jsonpath="{.data.password}" | base64 -d
```

Login : `admin` / mot de passe récupéré ci-dessus.

### 3. Installer la CLI ArgoCD
```bash
# macOS
brew install argocd

# Se connecter
argocd login localhost:8080 \
  --username admin \
  --password <mot-de-passe> \
  --insecure
```

## Déployer l'Application

### Option A — Manifest YAML (déclaratif, recommandé)

Modifier `application.yaml` en remplaçant `<votre-org>` par votre organisation GitHub :

```bash
kubectl apply -f application.yaml
```

### Option B — CLI ArgoCD
```bash
argocd app create postgresdb \
  --repo https://github.com/<votre-org>/k8s-tp-miage.git \
  --path postgres \
  --dest-server https://kubernetes.default.svc \
  --dest-namespace postgres \
  --sync-policy automated \
  --auto-prune \
  --self-heal
```

## Vérification et pilotage

```bash
# État de l'application
argocd app get postgresdb

# Synchronisation manuelle
argocd app sync postgresdb

# Historique
argocd app history postgresdb

# Ressources gérées
argocd app resources postgresdb
```

## Exercice — Simuler une dérive GitOps

C'est l'exercice fondateur pour comprendre le GitOps :

```bash
# 1. Modifier manuellement une variable dans le cluster
kubectl set env deployment/postgresdb POSTGRES_DB=wrongdb -n postgres

# 2. Observer la détection de dérive
argocd app get postgresdb
# STATUS: OutOfSync

# 3a. Si self-heal activé : ArgoCD corrige automatiquement
kubectl rollout status deployment/postgresdb -n postgres

# 3b. Si self-heal désactivé : synchroniser manuellement
argocd app sync postgresdb

# 4. Vérifier la restauration
kubectl exec -n postgres <nom-du-pod> -- env | grep POSTGRES_DB
# POSTGRES_DB=testdb
```

## Composants ArgoCD

| Composant | Rôle |
|-----------|------|
| `argocd-server` | API REST, interface web, endpoint gRPC |
| `argocd-application-controller` | Boucle de réconciliation GitOps (compare Git vs cluster) |
| `argocd-repo-server` | Clone les dépôts Git, rend les templates (Helm, Kustomize) |
| `argocd-redis` | Cache partagé entre les composants |
| `argocd-dex-server` | SSO/OIDC (GitHub, GitLab, LDAP, Okta) |
| `argocd-applicationset-controller` | Génère dynamiquement des Applications depuis des templates |

## SyncPolicy

| Option | Effet |
|--------|-------|
| `automated` | Synchronisation automatique quand Git change |
| `prune: true` | Supprime les ressources retirées de Git |
| `selfHeal: true` | Corrige les modifications manuelles dans le cluster |
| `CreateNamespace=true` | Crée le namespace s'il n'existe pas |

## Le principe GitOps
> Le cluster doit toujours refléter ce qui est dans Git — jamais l'inverse. Toute modification manuelle est une dérive à corriger, pas une pratique acceptable en production.

## Nettoyage
```bash
argocd app delete postgresdb
kubectl delete namespace argocd
```
