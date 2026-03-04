# TP07 - Helm — Packaging d'une application PostgreSQL

## Objectifs
- Comprendre la structure d'un chart Helm
- Créer un chart custom à partir de manifests existants
- Utiliser le templating Go pour paramétrer les déploiements
- Gérer les révisions et les rollbacks
- Surcharger les values pour différents environnements

## Prérequis
- `helm` installé (`brew install helm` ou [documentation officielle](https://helm.sh/docs/intro/install/))
- Cluster Kubernetes fonctionnel

## Structure du chart

```
postgresdb/
├── Chart.yaml              # Métadonnées (nom, version, description)
├── values.yaml             # Valeurs par défaut
├── templates/
│   ├── _helpers.tpl        # Fonctions Go réutilisables
│   ├── deployment.yaml     # Template du Deployment
│   ├── service.yaml        # Template du Service
│   └── pvc.yaml            # Template du PVC
values-prod.yaml            # Surcharge pour l'environnement de production
```

## Fichiers

| Fichier | Description |
|---------|-------------|
| `postgresdb/Chart.yaml` | Métadonnées du chart (version 0.1.0, appVersion 16.0) |
| `postgresdb/values.yaml` | Paramètres par défaut : image, env, service, storage, resources |
| `postgresdb/templates/deployment.yaml` | Deployment paramétré avec les values |
| `postgresdb/templates/service.yaml` | Service ClusterIP paramétré |
| `postgresdb/templates/pvc.yaml` | PVC paramétré (storageClass, taille) |
| `postgresdb/templates/_helpers.tpl` | Helpers : fullname, labels standards |
| `values-prod.yaml` | Surcharge de production (plus de ressources, credentials différents) |

## Utilisation pas à pas

### 1. Valider le chart
```bash
# Lint — vérifie la syntaxe
helm lint ./postgresdb

# Template — affiche les manifests générés sans appliquer
helm template postgresdb ./postgresdb --namespace postgres

# Dry-run complet
helm install postgresdb ./postgresdb \
  -n postgres --create-namespace --dry-run --debug
```

### 2. Installer
```bash
helm upgrade --install postgresdb ./postgresdb \
  -n postgres --create-namespace
```

### 3. Vérifier
```bash
# Statut de la release
helm status postgresdb -n postgres

# Ressources créées
kubectl get all -n postgres

# Values appliquées
helm get values postgresdb -n postgres

# Manifests rendus
helm get manifest postgresdb -n postgres
```

### 4. Mettre à jour avec les values de prod
```bash
helm upgrade postgresdb ./postgresdb \
  -f values-prod.yaml -n postgres
```

### 5. Historique et rollback
```bash
# Historique des révisions
helm history postgresdb -n postgres

# Rollback à la version précédente
helm rollback postgresdb -n postgres

# Rollback à une révision spécifique
helm rollback postgresdb 1 -n postgres
```

## Syntaxe Go templating

| Expression | Description |
|-----------|-------------|
| `{{ .Release.Name }}` | Nom de la release Helm |
| `{{ .Release.Namespace }}` | Namespace cible |
| `{{ .Values.image.tag }}` | Valeur depuis values.yaml |
| `{{ .Values.env.POSTGRES_DB \| quote }}` | Valeur entre guillemets |
| `{{- toYaml .Values.resources \| nindent 12 }}` | Conversion YAML avec indentation |

## Commandes Helm essentielles

| Commande | Description |
|----------|-------------|
| `helm lint` | Vérifie la syntaxe du chart |
| `helm template` | Affiche les manifests sans appliquer |
| `helm upgrade --install` | Install ou upgrade (idempotent) |
| `helm list -n <ns>` | Liste les releases |
| `helm status <release>` | Détail d'une release |
| `helm history <release>` | Historique des révisions |
| `helm rollback <release>` | Retour à la version précédente |
| `helm uninstall <release>` | Supprime la release et ses ressources |
| `helm show values <chart>` | Affiche les values par défaut |

## Nettoyage
```bash
helm uninstall postgresdb -n postgres
```

> **Attention** : `helm uninstall` supprime toutes les ressources, y compris le PVC. Les données seront perdues.
