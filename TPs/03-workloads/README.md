# TP03 - Workloads avancés

## Objectifs
- Créer et gérer des Jobs et CronJobs
- Déployer un DaemonSet sur tous les noeuds
- Utiliser un StatefulSet pour une base de données HA
- Implémenter les patterns Init Container et Sidecar

## Prérequis
- TP02 déployé (namespace `postgres`, secret `db-credentials`, service `postgresdb`)

## Fichiers

| Fichier | Description |
|---------|-------------|
| `job.yaml` | Job de migration de base de données (Flyway) |
| `cronjob.yaml` | CronJob de backup PostgreSQL (pg_dump tous les jours à 2h) |
| `daemonset.yaml` | DaemonSet Fluentd pour la collecte de logs |
| `statefulset.yaml` | StatefulSet PostgreSQL HA (3 replicas) avec Headless Service |
| `init-container.yaml` | Pod avec Init Container attendant PostgreSQL |
| `sidecar.yaml` | Pod avec Sidecar pattern (webapp + log-shipper) |

## Déploiement et tests

### Job — tâche ponctuelle
```bash
kubectl apply -f job.yaml

# Suivre le Job
kubectl get jobs -n postgres
kubectl logs job/migration-db -n postgres

# Nettoyage
kubectl delete job migration-db -n postgres
```

Le Job crée un pod qui s'exécute une fois puis se termine. `backoffLimit: 3` = 3 tentatives max en cas d'échec.

### CronJob — tâche planifiée
```bash
kubectl apply -f cronjob.yaml

# Vérifier la planification
kubectl get cronjobs -n postgres

# Déclencher manuellement pour tester
kubectl create job --from=cronjob/backup-postgres test-backup -n postgres

# Voir les Jobs générés
kubectl get jobs -n postgres

# Nettoyage
kubectl delete cronjob backup-postgres -n postgres
```

`concurrencyPolicy: Forbid` empêche les exécutions simultanées.

### DaemonSet — un pod par noeud
```bash
kubectl apply -f daemonset.yaml

# Vérifier : 1 pod par noeud
kubectl get daemonset fluentd -n kube-system
kubectl get pods -l app=fluentd -n kube-system -o wide

# Nettoyage
kubectl delete daemonset fluentd -n kube-system
```

Le DaemonSet Fluentd tourne sur chaque noeud (y compris le control-plane grâce à la toleration).

### Init Container — préparation avant démarrage
```bash
kubectl apply -f init-container.yaml

# Observer l'init container attendre PostgreSQL
kubectl get pod webapp -n postgres
# STATUS: Init:0/1 → Running

kubectl logs webapp -n postgres -c wait-for-db
# "Waiting for PostgreSQL..."
# "PostgreSQL is ready!"

# Nettoyage
kubectl delete pod webapp -n postgres
```

L'init container vérifie la connectivité vers `postgresdb:5432` via `nc -z` avant de laisser le conteneur principal démarrer.

### Sidecar — conteneur auxiliaire en parallèle
```bash
kubectl apply -f sidecar.yaml

# Vérifier que les 2 conteneurs tournent
kubectl get pod webapp-with-sidecar
# READY: 2/2

# Nettoyage
kubectl delete pod webapp-with-sidecar
```

Le pod contient 2 conteneurs partageant un volume `emptyDir` :
- `webapp` : écrit les logs dans `/app/logs`
- `log-shipper` : lit les logs depuis le même volume

### StatefulSet — pods avec identité stable
```bash
# ATTENTION : déployer dans un namespace sans service postgresdb existant,
# ou utiliser un nom distinct comme dans ce manifest (postgresdb-sts)
kubectl apply -f statefulset.yaml

# Vérifier les pods avec noms stables
kubectl get pods -l app=postgresdb-sts -n postgres
# postgresdb-sts-0   1/1   Running
# postgresdb-sts-1   1/1   Running
# postgresdb-sts-2   1/1   Running

# DNS stable pour chaque pod
# postgresdb-sts-0.postgresdb-headless.postgres.svc.cluster.local

# Nettoyage (attention : supprimer aussi les PVC créés automatiquement)
kubectl delete statefulset postgresdb-sts -n postgres
kubectl delete svc postgresdb-headless -n postgres
kubectl delete pvc -l app=postgresdb-sts -n postgres
```

## Comparaison des workloads

| Workload | Durée de vie | Identité | Cas d'usage |
|----------|-------------|----------|-------------|
| **Deployment** | Continue | Aléatoire | Apps stateless |
| **StatefulSet** | Continue | Stable (pod-0, pod-1) | Bases de données |
| **DaemonSet** | Continue | 1 par noeud | Agents système |
| **Job** | Ponctuelle | N/A | Migrations, batch |
| **CronJob** | Récurrente | N/A | Backups, maintenance |

## Patterns multi-conteneurs

| Pattern | Exécution | Usage |
|---------|-----------|-------|
| **Init Container** | Séquentiel, avant le main | Attendre une dépendance, préparer un volume |
| **Sidecar** | Parallèle, même durée de vie | Proxy, collecteur de logs, agent monitoring |
