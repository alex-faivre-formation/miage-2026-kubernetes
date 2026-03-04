# TP02 - Déploiement complet de PostgreSQL

## Objectifs
- Déployer PostgreSQL dans un namespace dédié
- Gérer la configuration via ConfigMap et Secrets
- Mettre en place du stockage persistant (PV/PVC)
- Configurer les probes de santé (liveness/readiness)
- Comprendre les différentes méthodes d'injection de variables d'environnement

## Prérequis
- Cluster Kubernetes fonctionnel
- StorageClass disponible (vérifier avec `kubectl get storageclass`)

## Fichiers

| Fichier | Description |
|---------|-------------|
| `namespace.yaml` | Namespace `postgres` dédié |
| `configmap.yaml` | ConfigMap avec les credentials PostgreSQL (en clair) |
| `secret.yaml` | Secret encodé en Base64 pour les credentials |
| `pv.yaml` | PersistentVolume de 8Gi |
| `pvc.yaml` | PersistentVolumeClaim |
| `deployment.yaml` | Deployment avec ConfigMap, probes et resources |
| `deployment-with-secret.yaml` | Variante utilisant un Secret via `envFrom` |
| `deployment-secret-volume.yaml` | Variante montant le Secret comme volume |
| `service.yaml` | Service ClusterIP pour accès interne |

## Déploiement pas à pas

### 1. Créer le namespace
```bash
kubectl apply -f namespace.yaml
```

### 2. Déployer la configuration
```bash
kubectl apply -f configmap.yaml
kubectl apply -f secret.yaml
```

### 3. Provisionner le stockage
```bash
kubectl apply -f pv.yaml
kubectl apply -f pvc.yaml
kubectl get pv,pvc -n postgres
```
Le PVC doit être en état `Bound`.

### 4. Déployer PostgreSQL (choisir UNE variante)

**Option A — Avec ConfigMap (développement) :**
```bash
kubectl apply -f deployment.yaml
```

**Option B — Avec Secret via envFrom (recommandé) :**
```bash
kubectl apply -f deployment-with-secret.yaml
```

**Option C — Avec Secret monté en volume (certificats, fichiers) :**
```bash
kubectl apply -f deployment-secret-volume.yaml
```

### 5. Exposer le service
```bash
kubectl apply -f service.yaml
```

### 6. Vérifier le déploiement
```bash
kubectl get all -n postgres
kubectl wait --for=condition=Ready pods -l app=postgresdb -n postgres --timeout=120s
```

### 7. Tester la connexion
```bash
# Port-forward pour accéder localement
kubectl port-forward svc/postgresdb 15432:5432 -n postgres

# Tester avec psql (dans un autre terminal)
psql -h localhost -p 15432 -U testuser -d testdb
```

## Probes de santé

Le deployment inclut deux probes PostgreSQL natives :

- **readinessProbe** : `pg_isready -U testuser -d testdb` — vérifie que PostgreSQL peut accepter des connexions (contrôle le routage du trafic)
- **livenessProbe** : `pg_isready -U testuser` — détecte les deadlocks et redémarre le conteneur si nécessaire

```bash
# Vérifier l'état des probes
kubectl describe pod -l app=postgresdb -n postgres | grep -A5 "Readiness\|Liveness"
```

## Trois méthodes d'injection des secrets

| Méthode | Fichier | Usage |
|---------|---------|-------|
| ConfigMap (`envFrom`) | `deployment.yaml` | Dev uniquement, valeurs en clair |
| Secret (`envFrom`) | `deployment-with-secret.yaml` | Variables scalaires, simple |
| Secret (volume) | `deployment-secret-volume.yaml` | Certificats TLS, mise à jour sans restart |

## Points importants

- **mountPath** : utiliser `/var/lib/postgresql` (et non `/var/lib/postgresql/data`) avec les versions récentes de PostgreSQL (18+)
- **StorageClass** : adapter selon votre cluster (`standard` pour minikube, `hostpath` pour Docker Desktop, `gp2` pour AWS EKS)
- **Secrets Base64** : l'encodage Base64 n'est PAS du chiffrement. En production, utiliser `EncryptionConfiguration` ou Vault

## Commandes de debug
```bash
# Logs PostgreSQL
kubectl logs -l app=postgresdb -n postgres

# Vérifier les variables d'environnement injectées
kubectl exec -n postgres <nom-du-pod> -- env | grep POSTGRES

# Vérifier les fichiers montés (variante volume)
kubectl exec -n postgres <nom-du-pod> -- ls /etc/secrets

# Events en cas de problème
kubectl get events -n postgres --sort-by='.lastTimestamp'
```

## Nettoyage
```bash
kubectl delete -f deployment.yaml
kubectl delete -f service.yaml
kubectl delete -f secret.yaml
kubectl delete -f configmap.yaml
kubectl delete -f pvc.yaml
kubectl delete -f pv.yaml
kubectl delete namespace postgres
```
