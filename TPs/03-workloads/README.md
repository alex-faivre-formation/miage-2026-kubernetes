# TP03 - Workloads avances

## Introduction theorique

Ce TP explore les differents types de workloads Kubernetes au-dela du Deployment classique. Chaque type repond a un besoin specifique : taches ponctuelles (Job), taches planifiees (CronJob), agents systeme (DaemonSet), applications stateful (StatefulSet) et patterns multi-conteneurs (Init Container, Sidecar).

Dans les TP01 et TP02, nous avons utilise des Pods nus et des Deployments. Ce sont les workloads les plus courants, mais Kubernetes offre une palette bien plus riche de controleurs, chacun adapte a un cas d'usage precis.

### Vue d'ensemble des workloads Kubernetes

```
                        Workloads Kubernetes
                               |
          +--------------------+--------------------+
          |                    |                    |
     Vie continue         Vie ponctuelle      Patterns
          |                    |              multi-conteneurs
    +-----+-----+       +-----+-----+            |
    |     |     |       |           |        +---+---+
Deployment| StatefulSet Job     CronJob  Init   Sidecar
    |  DaemonSet                      Container
    |
 (TP01-02)
```

Tous ces workloads utilisent des **controllers** (boucles de controle) qui surveillent l'etat reel du cluster et le rapprochent en permanence de l'etat desire. C'est le principe fondamental de Kubernetes : la **reconciliation declarative**.

```
+-------------------+       +-------------------+       +-------------------+
| Etat desire       |       | Controller        |       | Etat reel         |
| (manifests YAML)  | ----> | (boucle continue) | ----> | (cluster)         |
| "3 replicas"      |       | compare & agit    |       | "2 replicas"      |
+-------------------+       +-------------------+       +-------------------+
                                    |
                                    v
                            Cree 1 Pod manquant
```

### Job et CronJob

Un **Job** cree un ou plusieurs Pods pour executer une tache qui **se termine**. Contrairement a un Deployment, le Pod ne redemarre pas apres completion (exit code 0). Les cas d'usage typiques sont les migrations de base de donnees, les traitements batch, les imports de donnees et les tests d'integration.

Un **CronJob** est un Job planifie, equivalent au `cron` Linux. Il cree periodiquement des Jobs selon une expression cron.

```
CronJob "0 2 * * *"
    |
    | (tous les jours a 2h00)
    v
  Job (backup-postgres-28425180)
    |
    v
  Pod (backup-postgres-28425180-abc12)
    |
    v
  Container (pg_dump)
    |
    v
  Completed (exit code 0)
```

**Syntaxe cron rapide :**

```
+------------ minute (0-59)
| +---------- heure (0-23)
| | +-------- jour du mois (1-31)
| | | +------ mois (1-12)
| | | | +---- jour de la semaine (0-6, 0=dimanche)
| | | | |
* * * * *

Exemples :
"0 2 * * *"     -> tous les jours a 2h00
"*/5 * * * *"   -> toutes les 5 minutes
"0 0 * * 0"     -> tous les dimanches a minuit
"30 8 1 * *"    -> le 1er de chaque mois a 8h30
```

**Cycle de vie d'un Job :**

```
Job cree
    |
    v
Pod cree (status: Pending -> Running)
    |
    +-- Succes (exit code 0) --> Job status: Complete
    |
    +-- Echec (exit code != 0)
            |
            +-- backoffLimit non atteint --> Nouveau Pod cree (retry)
            |
            +-- backoffLimit atteint --> Job status: Failed
```

### DaemonSet

Un **DaemonSet** garantit qu'**exactement un Pod** tourne sur chaque noeud du cluster. Quand un nouveau noeud rejoint le cluster, le DaemonSet y deploie automatiquement un Pod. Quand un noeud est retire, le Pod est supprime.

Cas d'usage : collecte de logs (Fluentd, Filebeat), monitoring (node-exporter, Datadog agent), reseaux (CNI plugins, kube-proxy).

```
Cluster a 3 noeuds :

+-------------+  +-------------+  +-------------+
| Node 1      |  | Node 2      |  | Node 3      |
| +---------+ |  | +---------+ |  | +---------+ |
| | fluentd | |  | | fluentd | |  | | fluentd | |
| +---------+ |  | +---------+ |  | +---------+ |
| /var/log    |  | /var/log    |  | /var/log    |
+-------------+  +-------------+  +-------------+

Ajout d'un Node 4 :
+-------------+
| Node 4      |
| +---------+ |  <-- Pod fluentd cree automatiquement
| | fluentd | |
| +---------+ |
| /var/log    |
+-------------+
```

**Difference cle avec un Deployment :**
- Un Deployment deploie N replicas repartis par le scheduler sur les noeuds disponibles
- Un DaemonSet deploie exactement 1 replica **par noeud** (ou par noeud correspondant aux affinites/tolerations)

### StatefulSet

Un **StatefulSet** est comme un Deployment, mais avec des garanties supplementaires essentielles pour les applications **stateful** (bases de donnees, caches distribues, systemes de messagerie) :

| Propriete | Deployment | StatefulSet |
|-----------|-----------|-------------|
| Noms des Pods | Aleatoire (hash) | Ordonnes (pod-0, pod-1, pod-2) |
| DNS individuel | Non | Oui (via Headless Service) |
| Stockage | Partage (meme PVC) | Individuel (1 PVC par Pod) |
| Ordre de deploiement | Parallele | Sequentiel (0, 1, 2) |
| Ordre de suppression | Parallele | Sequentiel inverse (2, 1, 0) |

```
Headless Service (clusterIP: None)
postgresdb-headless.workloads.svc.cluster.local
    |
    +-- postgresdb-sts-0.postgresdb-headless.workloads.svc.cluster.local
    |        |
    |        +-- PVC: data-postgresdb-sts-0 (8Gi)
    |
    +-- postgresdb-sts-1.postgresdb-headless.workloads.svc.cluster.local
    |        |
    |        +-- PVC: data-postgresdb-sts-1 (8Gi)
    |
    +-- postgresdb-sts-2.postgresdb-headless.workloads.svc.cluster.local
             |
             +-- PVC: data-postgresdb-sts-2 (8Gi)
```

**Pourquoi un Headless Service ?**

Un Service normal (ClusterIP) attribue une IP virtuelle unique et fait du load balancing entre les Pods. Un Headless Service (`clusterIP: None`) ne fait pas de load balancing : il cree un enregistrement DNS **par Pod**. C'est indispensable pour les applications stateful ou chaque instance a un role different (ex: primary/replica dans un cluster de base de donnees).

```
Service ClusterIP normal :               Headless Service :

 client --> 10.96.0.10 (VIP)              client --> DNS lookup
                |                                      |
         load balancing                    +----------+----------+
           /    |    \                     |          |          |
        pod-0  pod-1  pod-2             pod-0      pod-1      pod-2
                                       10.244.0.5  10.244.1.3  10.244.2.7
```

### Patterns multi-conteneurs

Un Pod peut contenir plusieurs conteneurs qui partagent le meme reseau et les memes volumes :

**Init Container** : s'execute **avant** les conteneurs principaux, de maniere sequentielle. Utilise pour attendre une dependance, preparer un volume, ou telecharger une configuration.

**Sidecar** : s'execute **en parallele** du conteneur principal pendant toute la duree de vie du Pod. Utilise pour le logging, le monitoring, le proxy reseau (Envoy/Istio).

```
Init Container Pattern :            Sidecar Pattern :

+---------------------------+       +---------------------------+
| Pod                       |       | Pod                       |
|                           |       |                           |
| 1. [init: wait-for-db]   |       | [webapp]    [log-shipper] |
|    nc -z postgresdb 5432  |       |    |              ^       |
|         |                 |       |    | /app/logs     |       |
|         v (succes)        |       |    +-------+-------+       |
| 2. [main: webapp]        |       |            |               |
|    nginx:latest           |       |     emptyDir volume       |
+---------------------------+       +---------------------------+
```

**Cycle de vie d'un Pod avec Init Container :**

```
Pod cree
    |
    v
Init Container 1 demarre
    |
    +-- Succes --> Init Container 2 demarre (s'il existe)
    |                   |
    |                   +-- Succes --> Conteneurs principaux demarrent
    |
    +-- Echec --> Retry (selon restartPolicy)

Status du Pod : Init:0/1 --> Init:1/1 --> Running
```

## Objectifs

- Creer et gerer des Jobs et CronJobs
- Deployer un DaemonSet sur tous les noeuds
- Utiliser un StatefulSet pour une base de donnees avec identite stable
- Implementer les patterns Init Container et Sidecar
- Comprendre quand utiliser chaque type de workload

## Prerequis

- TP02 deploye (namespace `postgres`, secret `db-credentials`, service `postgresdb`)
- Cluster Kubernetes fonctionnel (minikube recommande)
- `kubectl` installe et configure

## Architecture deployee

```
Cluster Kubernetes
+----------------------------------------------------------------------+
|                                                                      |
|  Namespace: workloads                                                |
|  +----------------------------------------------------------------+  |
|  |                                                                |  |
|  |  +----------+    +-----------+    +------------------------+   |  |
|  |  | Job      |    | CronJob   |    | StatefulSet            |   |  |
|  |  | migration|    | backup    |    | postgresdb-sts         |   |  |
|  |  +----------+    +-----------+    | (3 replicas)           |   |  |
|  |                                   | + Headless Service     |   |  |
|  |  +-----------+   +------------+   | + volumeClaimTemplates |   |  |
|  |  | Pod       |   | Pod        |   +------------------------+   |  |
|  |  | webapp    |   | webapp +   |                                |  |
|  |  | + init    |   | sidecar    |                                |  |
|  |  +-----------+   +------------+                                |  |
|  +----------------------------------------------------------------+  |
|                                                                      |
|  Namespace: kube-system                                              |
|  +----------------------------------------------------------------+  |
|  |  DaemonSet: fluentd (1 Pod par noeud)                          |  |
|  +----------------------------------------------------------------+  |
|                                                                      |
+----------------------------------------------------------------------+
```

## Fichiers et explication detaillee

### `job.yaml` -- Job de migration de base de donnees

```yaml
apiVersion: batch/v1         # API batch pour les Jobs
kind: Job
metadata:
  name: migration-db
  namespace: workloads
spec:
  completions: 1             # 1 seule execution reussie necessaire
  parallelism: 1             # 1 seul Pod a la fois
  backoffLimit: 3            # 3 tentatives max en cas d'echec
  template:
    spec:
      restartPolicy: Never   # Obligatoire pour un Job (Never ou OnFailure)
      containers:
        - name: migration
          image: flyway/flyway:latest   # Outil de migration SQL
          args: ["migrate"]             # Commande de migration
          envFrom:
            - secretRef:
                name: db-credentials    # Credentials de la DB
```

**Champs importants :**
- `apiVersion: batch/v1` : les Jobs et CronJobs font partie du groupe d'API `batch`, pas du core (`v1`).
- `completions: 1` : le Job est considere comme termine quand 1 Pod se termine avec succes (exit code 0). Pour du traitement parallele, on peut augmenter cette valeur (ex: 10 taches a traiter).
- `parallelism: 1` : nombre de Pods executes en parallele. Avec `completions: 10` et `parallelism: 3`, Kubernetes execute 3 Pods en meme temps jusqu'a atteindre 10 completions.
- `backoffLimit: 3` : apres 3 echecs, le Job est marque comme `Failed`. Le delai entre les tentatives augmente exponentiellement (backoff exponentiel : 10s, 20s, 40s...).
- `restartPolicy: Never` : quand le conteneur echoue, un **nouveau Pod** est cree plutot que de redemarrer le meme. Avec `OnFailure`, le **meme Pod** est redemarre sur place (le compteur de restarts augmente).
- **Attention** : un Job ne peut pas avoir `restartPolicy: Always` (valeur par defaut des Deployments). Seuls `Never` et `OnFailure` sont autorises.

### `cronjob.yaml` -- CronJob de backup PostgreSQL

```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: backup-postgres
  namespace: workloads
spec:
  schedule: "0 2 * * *"           # Tous les jours a 2h00
  concurrencyPolicy: Forbid       # Empeche les executions simultanees
  successfulJobsHistoryLimit: 3   # Garde les 3 derniers Jobs reussis
  failedJobsHistoryLimit: 1       # Garde le dernier Job echoue
  jobTemplate:
    spec:
      template:
        spec:
          restartPolicy: OnFailure
          containers:
            - name: backup
              image: postgres:latest
              command: ["pg_dump", "-h", "postgresdb", "-U", "testuser", "testdb"]
              envFrom:
                - secretRef:
                    name: db-credentials
```

**Champs importants :**
- `schedule: "0 2 * * *"` : syntaxe cron standard (minute heure jour-du-mois mois jour-de-la-semaine). `"*/5 * * * *"` = toutes les 5 minutes.
- `concurrencyPolicy` :
  - `Allow` (defaut) : permet les executions simultanees
  - `Forbid` : si le Job precedent tourne encore, le nouveau est **ignore** (skipped)
  - `Replace` : le Job en cours est **tue** et remplace par le nouveau
- `successfulJobsHistoryLimit: 3` : conserve les 3 derniers Jobs reussis pour consultation. Les plus anciens sont automatiquement supprimes.
- `failedJobsHistoryLimit: 1` : conserve le dernier Job echoue pour analyse.
- La commande `pg_dump -h postgresdb` utilise le nom DNS du Service PostgreSQL du TP02.
- `jobTemplate` : le CronJob est une "factory" de Jobs. A chaque declenchement, il cree un nouveau Job a partir de ce template.

**Gestion du timezone :**
Le CronJob utilise le timezone du kube-controller-manager (generalement UTC). Depuis Kubernetes 1.27, on peut specifier un timezone avec le champ `timeZone: "Europe/Paris"`.

### `daemonset.yaml` -- DaemonSet Fluentd

```yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: fluentd
  namespace: kube-system          # Namespace systeme
spec:
  selector:
    matchLabels:
      app: fluentd
  template:
    metadata:
      labels:
        app: fluentd
    spec:
      tolerations:
        - key: node-role.kubernetes.io/control-plane
          effect: NoSchedule      # Autorise le deploiement sur le control-plane
      containers:
        - name: fluentd
          image: fluent/fluentd:latest
          volumeMounts:
            - name: varlog
              mountPath: /var/log       # Monte les logs du noeud
      volumes:
        - name: varlog
          hostPath:
            path: /var/log              # Repertoire de logs du noeud hote
```

**Champs importants :**
- `namespace: kube-system` : les agents systeme sont generalement deployes dans le namespace `kube-system`.
- **Pas de `replicas`** : un DaemonSet deploie automatiquement exactement 1 Pod par noeud correspondant aux tolerations et affinites.
- `tolerations` : par defaut, le control-plane a une **taint** `node-role.kubernetes.io/control-plane:NoSchedule` qui empeche les Pods normaux d'y etre schedules. Cette **toleration** autorise le DaemonSet a deployer Fluentd sur le control-plane egalement.
- `hostPath: /var/log` : monte le repertoire de logs du noeud hote directement dans le conteneur. Chaque instance de Fluentd collecte les logs de son propre noeud.

**Concept Taints et Tolerations :**

```
Noeud avec taint :                 Pod avec toleration :
+-------------------+              +-------------------+
| Node: control-plane|             | Pod: fluentd      |
| Taint:            |    MATCH     | Toleration:       |
|   key: node-role  | <---------> |   key: node-role  |
|   effect: NoSchedule            |   effect: NoSchedule
+-------------------+              +-------------------+
                                          |
                                          v
                                   Pod autorise sur ce noeud
```

Les taints sont posees sur les **noeuds** pour repousser les Pods. Les tolerations sont declarees dans les **Pods** pour indiquer qu'ils tolerent certaines taints. C'est l'inverse des affinites (qui attirent les Pods vers les noeuds).

### `statefulset.yaml` -- StatefulSet PostgreSQL HA

Ce fichier contient deux ressources : le Headless Service et le StatefulSet.

```yaml
apiVersion: v1
kind: Service
metadata:
  name: postgresdb-headless      # Headless Service (obligatoire pour StatefulSet)
  namespace: workloads
spec:
  clusterIP: None                # "None" = Headless Service
  selector:
    app: postgresdb-sts
  ports:
    - port: 5432
      targetPort: 5432
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: postgresdb-sts           # Nom different du Deployment TP02 pour eviter les conflits
  namespace: workloads
spec:
  serviceName: postgresdb-headless   # Reference au Headless Service
  replicas: 3                        # 3 instances
  selector:
    matchLabels:
      app: postgresdb-sts
  template:
    metadata:
      labels:
        app: postgresdb-sts
    spec:
      containers:
        - name: postgresdb
          image: postgres:latest
          envFrom:
            - secretRef:
                name: db-credentials
          volumeMounts:
            - name: data
              mountPath: /var/lib/postgresql   # Repertoire des donnees PostgreSQL
  volumeClaimTemplates:               # PVC cree automatiquement par Pod
    - metadata:
        name: data
      spec:
        storageClassName: standard    # StorageClass minikube
        accessModes: [ReadWriteOnce]  # Un seul noeud en ecriture par PVC
        resources:
          requests:
            storage: 8Gi
```

**Champs importants :**
- `clusterIP: None` : definit un Headless Service. Au lieu d'une IP unique avec load balancing, chaque Pod recoit son propre enregistrement DNS (ex: `postgresdb-sts-0.postgresdb-headless.workloads.svc.cluster.local`).
- `serviceName: postgresdb-headless` : obligatoire dans un StatefulSet. Lie le StatefulSet au Headless Service pour la resolution DNS individuelle.
- `name: postgresdb-sts` : on utilise un nom different du Deployment du TP02 (`postgresdb`) pour eviter les conflits si les deux TP sont deployes simultanement.
- `volumeClaimTemplates` : contrairement a un Deployment ou tous les Pods partagent le meme PVC, un StatefulSet cree un PVC **unique par Pod** automatiquement. Pas besoin de creer les PV/PVC manuellement si un provisioner dynamique est configure.
- `accessModes: [ReadWriteOnce]` : pour une base de donnees, chaque PVC est monte par un seul Pod a la fois. C'est le mode adapte aux applications stateful.
- **Attention** : les PVCs crees par un StatefulSet ne sont **pas supprimes** quand on supprime le StatefulSet. Il faut les supprimer manuellement (`kubectl delete pvc -l app=postgresdb-sts -n workloads`).

**Ordre de deploiement :**

```
Deploiement :                    Suppression :
postgresdb-sts-0  (cree)        postgresdb-sts-2  (supprime)
     |                                |
     v (une fois Ready)               v
postgresdb-sts-1  (cree)        postgresdb-sts-1  (supprime)
     |                                |
     v (une fois Ready)               v
postgresdb-sts-2  (cree)        postgresdb-sts-0  (supprime)
```

### `init-container.yaml` -- Init Container

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: webapp
  namespace: workloads
spec:
  initContainers:                    # Liste des init containers
    - name: wait-for-db
      image: busybox:latest          # Image legere (~1.5 Mo)
      command:
        - sh
        - -c
        - |
          until nc -z postgresdb 5432; do    # Test de connectivite TCP
            echo "Waiting for PostgreSQL..."
            sleep 2
          done
          echo "PostgreSQL is ready!"
  containers:                        # Conteneur principal
    - name: webapp
      image: nginx:latest
      ports:
        - containerPort: 8080
```

**Champs importants :**
- `initContainers` : liste de conteneurs executes sequentiellement avant les conteneurs principaux. Si un init container echoue, Kubernetes le redemarre jusqu'au succes (ou atteinte du `restartPolicy`).
- `nc -z postgresdb 5432` : `nc` (netcat) teste la connectivite TCP vers le service `postgresdb` sur le port 5432. L'option `-z` scanne sans envoyer de donnees.
- L'init container utilise `busybox` (image ultra-legere) car il n'a besoin que de `nc` et `sh`.
- L'init container a acces aux memes volumes que le conteneur principal, ce qui permet de preparer des donnees avant le demarrage.
- Le Pod affiche le statut `Init:0/1` tant que l'init container n'a pas termine.
- Plusieurs init containers sont executes dans l'ordre de declaration. Chaque init container doit reussir avant que le suivant ne demarre.

### `sidecar.yaml` -- Sidecar Pattern

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: webapp-with-sidecar
spec:
  containers:
    - name: webapp                    # Conteneur principal
      image: nginx:latest
      volumeMounts:
        - name: logs
          mountPath: /app/logs        # Ecrit les logs ici

    - name: log-shipper               # Sidecar
      image: fluent/fluent-bit:latest
      volumeMounts:
        - name: logs
          mountPath: /app/logs
          readOnly: true              # Le sidecar lit seulement

  volumes:
    - name: logs
      emptyDir: {}                    # Volume ephemere partage
```

**Champs importants :**
- Les deux conteneurs partagent le volume `logs` (type `emptyDir`). `emptyDir` est un volume vide cree quand le Pod est assigne a un noeud et supprime quand le Pod disparait.
- `readOnly: true` sur le sidecar : bonne pratique de securite, le log-shipper n'a pas besoin d'ecrire dans les logs.
- Les deux conteneurs partagent aussi le meme reseau (meme IP, meme `localhost`), ce qui permet au sidecar d'exposer un endpoint de metriques sur un port different.
- Le pattern sidecar est a la base des service meshes comme **Istio** (qui injecte automatiquement un proxy Envoy en sidecar dans chaque Pod).
- Depuis Kubernetes 1.29+, il existe un support natif des sidecars via `restartPolicy: Always` dans les init containers, ce qui garantit que le sidecar demarre avant les conteneurs principaux.

**Communication entre conteneurs du meme Pod :**

```
+-------------------------------------------+
| Pod: webapp-with-sidecar                  |
|                                           |
| +-------------+     +------------------+ |
| | webapp      |     | log-shipper      | |
| | (nginx)     |     | (fluent-bit)     | |
| | port: 80    |     | port: 2020       | |
| +------+------+     +--------+---------+ |
|        |                      |           |
|        |   meme localhost     |           |
|        +--------- IP: 10.244.0.5 --------+           |
|        |                      |           |
|   +----+----------------------+----+      |
|   |     emptyDir: /app/logs        |      |
|   +--------------------------------+      |
+-------------------------------------------+
```

## Deploiement et tests pas a pas

### 0. Creer le namespace workloads

```bash
kubectl create namespace workloads
```

Sortie attendue :
```
namespace/workloads created
```

**Note** : le Job, le CronJob, l'init container et le StatefulSet referent au secret `db-credentials` du namespace `postgres` (TP02). Pour les deployer dans le namespace `workloads`, il faudra soit copier le secret, soit adapter les fichiers. Le DaemonSet est deploye dans `kube-system` et n'a pas besoin de ce secret.

### 1. Job -- tache ponctuelle

```bash
kubectl apply -f job.yaml
```

Sortie attendue :
```
job.batch/migration-db created
```

Suivre l'execution du Job :
```bash
# Etat du Job
kubectl get jobs -n workloads
```

Sortie attendue :
```
NAME           COMPLETIONS   DURATION   AGE
migration-db   1/1           8s         15s
```

```bash
# Logs du Pod cree par le Job
kubectl logs job/migration-db -n workloads

# Voir le Pod cree (status Completed)
kubectl get pods -n workloads -l job-name=migration-db
```

Sortie attendue :
```
NAME                     READY   STATUS      RESTARTS   AGE
migration-db-abc12       0/1     Completed   0          20s
```

Nettoyage :
```bash
kubectl delete job migration-db -n workloads
```

### 2. CronJob -- tache planifiee

```bash
kubectl apply -f cronjob.yaml
```

Sortie attendue :
```
cronjob.batch/backup-postgres created
```

Verifier la planification :
```bash
kubectl get cronjobs -n workloads
```

Sortie attendue :
```
NAME              SCHEDULE    SUSPEND   ACTIVE   LAST SCHEDULE   AGE
backup-postgres   0 2 * * *   False     0        <none>          10s
```

Declencher manuellement pour tester (sans attendre 2h00) :
```bash
kubectl create job --from=cronjob/backup-postgres test-backup -n workloads
```

Sortie attendue :
```
job.batch/test-backup created
```

Voir les Jobs generes :
```bash
kubectl get jobs -n workloads
```

Sortie attendue :
```
NAME          COMPLETIONS   DURATION   AGE
test-backup   1/1           5s         12s
```

Voir les logs du backup :
```bash
kubectl logs job/test-backup -n workloads
```

Nettoyage :
```bash
kubectl delete cronjob backup-postgres -n workloads
kubectl delete job test-backup -n workloads
```

### 3. DaemonSet -- un Pod par noeud

```bash
kubectl apply -f daemonset.yaml
```

Sortie attendue :
```
daemonset.apps/fluentd created
```

Verifier : 1 Pod par noeud :
```bash
kubectl get daemonset fluentd -n kube-system
```

Sortie attendue (sur minikube avec 1 noeud) :
```
NAME      DESIRED   CURRENT   READY   UP-TO-DATE   AVAILABLE   NODE SELECTOR   AGE
fluentd   1         1         1       1             1           <none>          15s
```

Voir sur quel noeud tourne chaque Pod :
```bash
kubectl get pods -l app=fluentd -n kube-system -o wide
```

Sortie attendue :
```
NAME            READY   STATUS    RESTARTS   AGE   IP            NODE
fluentd-x7k2p   1/1     Running   0          20s   10.244.0.8    minikube
```

Nettoyage :
```bash
kubectl delete daemonset fluentd -n kube-system
```

### 4. Init Container -- preparation avant demarrage

```bash
kubectl apply -f init-container.yaml
```

Observer l'init container attendre PostgreSQL :
```bash
kubectl get pod webapp -n workloads -w
```

Sortie attendue (en temps reel avec `-w`) :
```
NAME     READY   STATUS     RESTARTS   AGE
webapp   0/1     Init:0/1   0          2s
webapp   0/1     Init:0/1   0          4s
webapp   1/1     Running    0          12s
```

Voir les logs de l'init container :
```bash
kubectl logs webapp -n workloads -c wait-for-db
```

Sortie attendue :
```
Waiting for PostgreSQL...
Waiting for PostgreSQL...
PostgreSQL is ready!
```

Nettoyage :
```bash
kubectl delete pod webapp -n workloads
```

### 5. Sidecar -- conteneur auxiliaire en parallele

```bash
kubectl apply -f sidecar.yaml
```

Verifier que les 2 conteneurs tournent :
```bash
kubectl get pod webapp-with-sidecar
```

Sortie attendue :
```
NAME                  READY   STATUS    RESTARTS   AGE
webapp-with-sidecar   2/2     Running   0          10s
```

Le `2/2` dans la colonne READY confirme que les deux conteneurs (webapp et log-shipper) sont operationnels.

Voir les logs de chaque conteneur :
```bash
# Logs du conteneur principal
kubectl logs webapp-with-sidecar -c webapp

# Logs du sidecar
kubectl logs webapp-with-sidecar -c log-shipper
```

Nettoyage :
```bash
kubectl delete pod webapp-with-sidecar
```

### 6. StatefulSet -- Pods avec identite stable

```bash
kubectl apply -f statefulset.yaml
```

Sortie attendue :
```
service/postgresdb-headless created
statefulset.apps/postgresdb-sts created
```

Observer la creation ordonnee des Pods :
```bash
kubectl get pods -l app=postgresdb-sts -n workloads -w
```

Sortie attendue (les Pods sont crees **un par un**, dans l'ordre) :
```
NAME               READY   STATUS    RESTARTS   AGE
postgresdb-sts-0   0/1     Pending   0          1s
postgresdb-sts-0   1/1     Running   0          15s
postgresdb-sts-1   0/1     Pending   0          1s
postgresdb-sts-1   1/1     Running   0          12s
postgresdb-sts-2   0/1     Pending   0          1s
postgresdb-sts-2   1/1     Running   0          10s
```

Verifier les PVCs crees automatiquement :
```bash
kubectl get pvc -n workloads
```

Sortie attendue :
```
NAME                      STATUS   VOLUME          CAPACITY   ACCESS MODES   STORAGECLASS   AGE
data-postgresdb-sts-0     Bound    pvc-abc123...   8Gi        RWO            standard       45s
data-postgresdb-sts-1     Bound    pvc-def456...   8Gi        RWO            standard       30s
data-postgresdb-sts-2     Bound    pvc-ghi789...   8Gi        RWO            standard       15s
```

Tester le DNS stable :
```bash
kubectl run -it --rm dns-test --image=busybox -n workloads -- \
  nslookup postgresdb-sts-0.postgresdb-headless.workloads.svc.cluster.local
```

Sortie attendue :
```
Server:    10.96.0.10
Address 1: 10.96.0.10 kube-dns.kube-system.svc.cluster.local

Name:      postgresdb-sts-0.postgresdb-headless.workloads.svc.cluster.local
Address 1: 10.244.0.15 postgresdb-sts-0.postgresdb-headless.workloads.svc.cluster.local
```

Nettoyage (attention : supprimer aussi les PVCs) :
```bash
kubectl delete statefulset postgresdb-sts -n workloads
kubectl delete svc postgresdb-headless -n workloads
kubectl delete pvc -l app=postgresdb-sts -n workloads
```

## Comparaison des workloads

| Workload | Duree de vie | Identite | Nombre de Pods | Cas d'usage |
|----------|-------------|----------|----------------|-------------|
| **Deployment** | Continue | Aleatoire (hash) | N replicas (configurable) | Apps stateless (API, web) |
| **StatefulSet** | Continue | Stable (pod-0, pod-1) | N replicas (ordonne) | Bases de donnees, caches |
| **DaemonSet** | Continue | 1 par noeud | 1 par noeud (automatique) | Agents systeme, monitoring |
| **Job** | Ponctuelle | N/A | 1 a N (configurable) | Migrations, batch, import |
| **CronJob** | Recurrente | N/A | 1 a N par execution | Backups, nettoyage, rapports |

## Patterns multi-conteneurs -- resume

| Pattern | Execution | Volume partage | Cas d'usage |
|---------|-----------|---------------|-------------|
| **Init Container** | Sequentiel, avant le main | Oui | Attendre une dependance, preparer un volume, telecharger une config |
| **Sidecar** | Parallele, meme duree de vie | Oui | Proxy reseau, collecteur de logs, agent monitoring |

## Exercice pratique

1. **Deployer le Job** `migration-db` et observer les Pods crees. Verifier que le Job passe en status `Complete`.
2. **Deployer le CronJob** et le declencher manuellement avec `kubectl create job --from=cronjob/backup-postgres`. Observer le Job cree.
3. **Deployer le DaemonSet** et verifier qu'il y a bien 1 Pod par noeud (`kubectl get pods -o wide`).
4. **Deployer l'init container** et observer le statut `Init:0/1` se transformer en `Running`.
5. **Deployer le StatefulSet** et observer :
   - Les Pods crees dans l'ordre (0, 1, 2)
   - Les PVCs crees automatiquement
   - Le DNS stable via `nslookup`
6. **Supprimer le Pod `postgresdb-sts-1`** et observer que le StatefulSet le recree avec le **meme nom** et le **meme PVC**.

## Troubleshooting

### Le Job echoue avec `BackoffLimitExceeded`

**Cause** : le conteneur echoue plus de fois que le `backoffLimit` (3 par defaut).
```bash
kubectl describe job migration-db -n workloads
kubectl logs job/migration-db -n workloads
```
**Solution** : corriger la cause de l'echec (credentials, image, commande) et **recreer** le Job. Un Job en echec ne peut pas etre reapplique, il faut le supprimer et le recreer :
```bash
kubectl delete job migration-db -n workloads
kubectl apply -f job.yaml
```

### Le CronJob ne se declenche pas

**Cause probable** : la syntaxe cron est incorrecte ou le timezone du cluster n'est pas celui attendu.
```bash
kubectl describe cronjob backup-postgres -n workloads
# Verifier "Last Schedule Time" et "Active"
```
**Solution** : tester avec un declenchement manuel :
```bash
kubectl create job --from=cronjob/backup-postgres test -n workloads
```

### L'Init Container reste bloque indefiniment

**Cause** : le service cible (ici `postgresdb`) n'existe pas ou n'est pas accessible depuis le namespace du Pod.
```bash
kubectl logs webapp -n workloads -c wait-for-db
# "Waiting for PostgreSQL..." en boucle
```
**Solution** : verifier que le service PostgreSQL du TP02 est deploye. Si le Pod est dans un namespace different de `postgres`, utiliser le FQDN : `postgresdb.postgres.svc.cluster.local`.

### Le StatefulSet ne cree pas tous les Pods

**Cause probable** : pas assez de PVs disponibles pour les PVCs, ou pas de provisioner dynamique configure.
```bash
kubectl get pvc -n workloads
# Les PVCs en "Pending" bloquent la creation des Pods suivants
```
**Solution** : verifier que la StorageClass `standard` a un provisioner dynamique. Sur minikube, c'est le cas par defaut. Sinon, creer les PVs manuellement.
```bash
kubectl get storageclass
# Verifier la colonne PROVISIONER
```

### Le DaemonSet montre 0 Pods schedules

**Cause probable** : les noeuds ont des taints qui empechent le scheduling.
```bash
kubectl describe nodes | grep Taints
```
**Solution** : ajouter les tolerations correspondantes dans la spec du DaemonSet.

### Le Sidecar est en `CrashLoopBackOff` mais le conteneur principal fonctionne

**Cause probable** : le sidecar ne trouve pas les fichiers attendus ou manque de configuration.
```bash
kubectl logs webapp-with-sidecar -c log-shipper
kubectl describe pod webapp-with-sidecar
```
**Solution** : verifier que le volume partage est correctement monte et que le conteneur principal ecrit bien dans le repertoire attendu.

### Les PVCs du StatefulSet ne sont pas supprimes apres `kubectl delete statefulset`

**C'est le comportement normal !** Les PVCs crees par `volumeClaimTemplates` sont conserves intentionnellement pour proteger les donnees. Il faut les supprimer manuellement :
```bash
kubectl delete pvc -l app=postgresdb-sts -n workloads
```

## Commandes de debug

```bash
# Voir tous les workloads du namespace
kubectl get all -n workloads

# Voir l'historique des Jobs (reussis et echoues)
kubectl get jobs -n workloads

# Voir les events recents (utile pour comprendre les erreurs)
kubectl get events -n workloads --sort-by='.lastTimestamp'

# Voir les logs d'un conteneur specifique dans un Pod multi-conteneurs
kubectl logs <pod-name> -c <container-name> -n workloads

# Voir l'etat detaille d'un StatefulSet
kubectl describe statefulset postgresdb-sts -n workloads

# Voir le rollout status d'un StatefulSet
kubectl rollout status statefulset postgresdb-sts -n workloads
```

## Nettoyage complet

```bash
# Supprimer les workloads
kubectl delete -f job.yaml --ignore-not-found
kubectl delete -f cronjob.yaml --ignore-not-found
kubectl delete -f init-container.yaml --ignore-not-found
kubectl delete -f sidecar.yaml --ignore-not-found
kubectl delete -f statefulset.yaml --ignore-not-found

# Supprimer les PVCs du StatefulSet
kubectl delete pvc -l app=postgresdb-sts -n workloads

# Supprimer le DaemonSet (namespace kube-system)
kubectl delete -f daemonset.yaml --ignore-not-found

# Supprimer le namespace
kubectl delete namespace workloads
```

## Pour aller plus loin

- [Documentation officielle Kubernetes : Jobs](https://kubernetes.io/docs/concepts/workloads/controllers/job/)
- [Documentation officielle Kubernetes : CronJobs](https://kubernetes.io/docs/concepts/workloads/controllers/cron-jobs/)
- [Documentation officielle Kubernetes : DaemonSets](https://kubernetes.io/docs/concepts/workloads/controllers/daemonset/)
- [Documentation officielle Kubernetes : StatefulSets](https://kubernetes.io/docs/concepts/workloads/controllers/statefulset/)
- [Documentation officielle Kubernetes : Init Containers](https://kubernetes.io/docs/concepts/workloads/pods/init-containers/)
- [Documentation officielle Kubernetes : Sidecar Containers](https://kubernetes.io/docs/concepts/workloads/pods/sidecar-containers/)
- [Taints and Tolerations](https://kubernetes.io/docs/concepts/scheduling-eviction/taint-and-toleration/)

**Suggestions d'amelioration :**
- Ajouter un `activeDeadlineSeconds` au Job pour limiter le temps d'execution total
- Configurer le CronJob pour stocker les backups dans un volume persistant ou un bucket S3
- Ajouter des `resources` aux conteneurs du DaemonSet pour eviter la famine de ressources
- Implementer la replication PostgreSQL dans le StatefulSet (primary/replica avec streaming replication)
- Utiliser le Sidecar pattern natif de Kubernetes 1.29+ (avec `restartPolicy: Always` dans les init containers)
- Explorer les `PodDisruptionBudgets` pour proteger les StatefulSets lors des maintenances de cluster

## QCM de revision

**Question 1** : Quelle est la difference entre `restartPolicy: Never` et `restartPolicy: OnFailure` dans un Job ?

- A) `Never` cree un nouveau Pod a chaque echec, `OnFailure` redemarre le meme Pod
- B) `Never` ne retente jamais, `OnFailure` retente indefiniment
- C) Il n'y a pas de difference
- D) `Never` est pour les Jobs, `OnFailure` est pour les CronJobs

<details>
<summary>Reponse</summary>
<b>A)</b> Avec <code>Never</code>, quand le conteneur echoue, un nouveau Pod est cree (l'ancien reste visible avec le statut Error). Avec <code>OnFailure</code>, le meme Pod est redemarre sur place (le compteur de restarts augmente). Dans les deux cas, le <code>backoffLimit</code> s'applique pour limiter le nombre total de tentatives.
</details>

---

**Question 2** : Pourquoi un StatefulSet necessite-t-il un Headless Service ?

- A) Pour economiser une IP ClusterIP
- B) Pour fournir un enregistrement DNS individuel a chaque Pod (ex: pod-0.service.namespace)
- C) Pour empecher le load balancing
- D) C'est optionnel, un Service normal fonctionne aussi

<details>
<summary>Reponse</summary>
<b>B)</b> Un Headless Service (<code>clusterIP: None</code>) ne fournit pas de load balancing. A la place, il cree un enregistrement DNS pour chaque Pod du StatefulSet (ex: <code>postgresdb-sts-0.postgresdb-headless.workloads.svc.cluster.local</code>). C'est essentiel pour les applications stateful qui ont besoin d'adresser un Pod specifique (ex: le primary d'un cluster de base de donnees).
</details>

---

**Question 3** : Que signifie `concurrencyPolicy: Forbid` sur un CronJob ?

- A) Le CronJob ne peut pas creer plus d'un Pod
- B) Si le Job de l'execution precedente tourne encore, la nouvelle execution est sautee
- C) Deux CronJobs ne peuvent pas avoir le meme nom
- D) Le CronJob est desactive

<details>
<summary>Reponse</summary>
<b>B)</b> Avec <code>Forbid</code>, si le Job lance par l'execution precedente n'est pas encore termine quand la prochaine execution est planifiee, celle-ci est purement et simplement ignoree. C'est crucial pour les backups de base de donnees ou deux executions simultanees pourraient causer des conflits ou de la corruption de donnees.
</details>

---

**Question 4** : Dans quel ordre les init containers s'executent-ils ?

- A) En parallele, comme les conteneurs normaux
- B) De maniere sequentielle, dans l'ordre de declaration
- C) Dans un ordre aleatoire
- D) Le premier qui est pret demarre en premier

<details>
<summary>Reponse</summary>
<b>B)</b> Les init containers s'executent strictement dans l'ordre de declaration dans le manifest. Chaque init container doit se terminer avec succes (exit code 0) avant que le suivant ne demarre. Les conteneurs principaux ne demarrent que quand <b>tous</b> les init containers ont reussi.
</details>

---

**Question 5** : Quelle est la difference principale entre un DaemonSet et un Deployment avec `replicas: N` ?

- A) Un DaemonSet est plus performant
- B) Un DaemonSet garantit exactement 1 Pod par noeud, un Deployment repartit N Pods librement sur les noeuds disponibles
- C) Un DaemonSet ne supporte pas les volumes
- D) Un Deployment ne peut pas tourner sur le control-plane

<details>
<summary>Reponse</summary>
<b>B)</b> Un DaemonSet place exactement 1 Pod sur chaque noeud (ou chaque noeud correspondant aux tolerations/affinites). Le nombre total de Pods est egal au nombre de noeuds. Un Deployment place N Pods sur les noeuds disponibles selon les decisions du scheduler, potentiellement plusieurs sur le meme noeud.
</details>

---

**Question 6** : Que se passe-t-il si on supprime le Pod `postgresdb-sts-1` d'un StatefulSet a 3 replicas ?

- A) Le StatefulSet cree un nouveau Pod avec un nom aleatoire
- B) Le StatefulSet recree un Pod nomme `postgresdb-sts-1` avec le meme PVC
- C) Le StatefulSet reduit ses replicas a 2
- D) Le StatefulSet recree les 3 Pods

<details>
<summary>Reponse</summary>
<b>B)</b> Le StatefulSet recree un Pod avec exactement le meme nom (<code>postgresdb-sts-1</code>) et le rattache au meme PVC (<code>data-postgresdb-sts-1</code>). C'est la garantie d'<b>identite stable</b> du StatefulSet : le Pod retrouve ses donnees meme apres un redemarrage. C'est cette propriete qui rend les StatefulSets adaptes aux bases de donnees.
</details>

---

**Question 7** : A quoi sert le champ `volumeClaimTemplates` dans un StatefulSet ?

- A) Il cree un PVC unique partage par tous les Pods
- B) Il cree un PVC individuel pour chaque Pod du StatefulSet
- C) Il permet de monter un ConfigMap comme volume
- D) Il definit les limites de stockage du namespace

<details>
<summary>Reponse</summary>
<b>B)</b> Le <code>volumeClaimTemplates</code> est un template de PVC. Pour chaque replica du StatefulSet, Kubernetes cree un PVC unique nomme <code>{template-name}-{pod-name}</code> (ex: <code>data-postgresdb-sts-0</code>, <code>data-postgresdb-sts-1</code>). Chaque Pod a donc son propre volume persistant isole, ce qui est essentiel pour les applications stateful.
</details>
