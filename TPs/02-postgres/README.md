# TP02 - Deploiement complet de PostgreSQL

## Introduction theorique

Ce TP approfondit les concepts de deploiement en Kubernetes a travers une stack PostgreSQL complete. Nous allons manipuler la **gestion de la configuration** (ConfigMap et Secrets), le **stockage persistant** (PersistentVolume et PersistentVolumeClaim), les **probes de sante** (liveness et readiness) et les differentes methodes d'injection de variables d'environnement.

Contrairement au TP01 ou nous avons deploye un serveur web stateless (Nginx), PostgreSQL est une application **stateful** : elle ecrit des donnees sur disque et a besoin que ces donnees survivent aux redemarrages. Cela introduit des problematiques nouvelles : ou stocker les donnees ? comment passer les credentials de maniere securisee ? comment savoir si la base est prete ?

### ConfigMap vs Secret

Kubernetes propose deux mecanismes pour fournir de la configuration aux conteneurs :

```
+-------------------+        +-------------------+
|    ConfigMap      |        |     Secret        |
|-------------------|        |-------------------|
| Donnees en clair  |        | Donnees en Base64 |
| Config applicative|        | Mots de passe     |
| Variables d'env   |        | Tokens API        |
| Fichiers de conf  |        | Certificats TLS   |
+-------------------+        +-------------------+
        |                            |
        v                            v
   envFrom:                    envFrom:
     configMapRef                secretRef
   OU                          OU
   volume mount                volume mount
```

Les deux peuvent etre injectes comme variables d'environnement (`envFrom`) ou montes comme fichiers dans un volume. La difference majeure est que les Secrets sont stockes de maniere plus restreinte dans etcd et peuvent etre chiffres au repos avec `EncryptionConfiguration`.

**Important** : l'encodage Base64 des Secrets n'est **PAS** du chiffrement. C'est un simple encodage reversible (`echo "dGVzdHVzZXI=" | base64 -d` donne `testuser`). En production, il faut activer le chiffrement au repos ou utiliser une solution comme HashiCorp Vault (voir TP10).

### Comment Kubernetes injecte la configuration dans un conteneur ?

Il existe trois methodes principales pour injecter des variables d'environnement depuis un ConfigMap ou un Secret :

```
Methode 1 : envFrom (injecte TOUTES les cles)
+-------------+                    +-------------------+
| ConfigMap   |  envFrom:          | Conteneur         |
| POSTGRES_DB |  configMapRef: --> | env: POSTGRES_DB  |
| POSTGRES_USER|   name: creds    | env: POSTGRES_USER|
| POSTGRES_PASS|                  | env: POSTGRES_PASS|
+-------------+                    +-------------------+

Methode 2 : env (injecte des cles specifiques)
+-------------+                    +-------------------+
| Secret      |  env:              | Conteneur         |
| POSTGRES_USER| - name: DB_USER  | env: DB_USER      |
| POSTGRES_PASS|   valueFrom:     |                   |
+-------------+   secretKeyRef    +-------------------+

Methode 3 : volume mount (monte comme fichiers)
+-------------+                    +-------------------+
| Secret      |  volume mount:    | Conteneur         |
| POSTGRES_USER| /etc/secrets/ -> | /etc/secrets/     |
| POSTGRES_PASS|                  |   POSTGRES_USER   |
+-------------+                    |   POSTGRES_PASS   |
                                   +-------------------+
```

### Stockage persistant : PV et PVC

Par defaut, le systeme de fichiers d'un conteneur est **ephemere** : les donnees sont perdues quand le Pod disparait. Pour une base de donnees, c'est inacceptable.

Kubernetes separe la **provision du stockage** (PersistentVolume, administre par l'ops) de la **demande de stockage** (PersistentVolumeClaim, faite par le developpeur) :

```
Administrateur                     Developpeur
     |                                  |
     v                                  v
+------------+    binding       +-----------+
|     PV     | <--------------> |    PVC    |
| 8Gi        |   (automatique)  | 8Gi       |
| hostPath   |                  | standard  |
| standard   |                  |           |
+------------+                  +-----------+
                                      |
                                      v
                               +------------+
                               | Deployment |
                               | volumeMount|
                               +------------+
```

Le binding entre PV et PVC est automatique si les criteres correspondent : meme `storageClassName`, `accessModes` compatible, capacite suffisante.

**Les modes d'acces :**

| Mode | Abreviation | Description |
|------|-------------|-------------|
| ReadWriteOnce | RWO | Un seul noeud peut monter le volume en lecture/ecriture |
| ReadOnlyMany | ROX | Plusieurs noeuds peuvent monter le volume en lecture seule |
| ReadWriteMany | RWX | Plusieurs noeuds peuvent monter le volume en lecture/ecriture |
| ReadWriteOncePod | RWOP | Un seul Pod peut monter le volume (Kubernetes 1.22+) |

Pour une base de donnees mono-instance, `ReadWriteOnce` (RWO) est le mode recommande.

### Cycle de vie du stockage

```
                  PVC cree          PV compatible
                     |              trouve
   PVC: Pending ---->+-----> PVC: Bound -----> Utilisation normale
                     |                              |
                     |                              | PVC supprime
                     v                              v
              PV non trouve               PV: Released
              (reste Pending)                   |
                                    +-----------+-----------+
                                    |                       |
                              reclaimPolicy:          reclaimPolicy:
                                Retain                  Delete
                                    |                       |
                                    v                       v
                              PV conserve            PV + donnees
                              (admin decide)         supprimes
```

### Probes de sante

Kubernetes utilise des probes pour surveiller l'etat des conteneurs :

- **readinessProbe** : determine si le conteneur est **pret a recevoir du trafic**. Si la probe echoue, le Pod est retire des endpoints du Service (plus de trafic) mais n'est pas redemarre.
- **livenessProbe** : determine si le conteneur est **en vie**. Si la probe echoue, Kubernetes redemarre le conteneur.
- **startupProbe** (non utilise ici) : donne du temps au conteneur pour demarrer avant que les autres probes ne prennent le relais.

```
Demarrage du Pod
     |
     | initialDelaySeconds (5s pour readiness, 30s pour liveness)
     v
+----+----+     periodSeconds (10s/20s)     +--------+
| Probe   | --------------------------->    | Probe  | ---> ...
| exec    |                                 | exec   |
| pg_isready                                | pg_isready
+----+----+                                 +--------+
     |
     +-- Succes : Pod READY, trafic route
     +-- Echec (x failureThreshold) : Pod NOT READY / restart
```

**Types de probes disponibles :**

| Type | Description | Exemple |
|------|-------------|---------|
| `exec` | Execute une commande dans le conteneur | `pg_isready -U testuser` |
| `httpGet` | Requete HTTP GET sur un endpoint | `path: /health, port: 8080` |
| `tcpSocket` | Test de connectivite TCP | `port: 5432` |
| `grpc` | Verification gRPC (Kubernetes 1.24+) | `port: 50051` |

Pour PostgreSQL, `exec` avec `pg_isready` est la methode la plus fiable car elle verifie reellement que le moteur de base de donnees accepte les connexions, pas seulement que le port est ouvert.

### Pourquoi un Deployment et pas un Pod nu ?

Dans le TP01, nous avons deploye Nginx comme un Pod nu. Ici, nous utilisons un **Deployment**. La difference est cruciale :

```
Pod nu (TP01)                   Deployment (TP02)
+--------+                      +--------------+
| Pod    |                      | Deployment   |
| nginx  |                      |   |          |
+--------+                      |   v          |
    |                           | ReplicaSet   |
    | Si le Pod meurt           |   |          |
    v                           |   v          |
  Perdu !                       | Pod recree   |
  Aucun mecanisme               | automatiquement
  de recreation                 +--------------+
```

Le Deployment gere un **ReplicaSet** qui garantit que le nombre de replicas souhaite (ici 1) est toujours respecte. Si le Pod tombe, le ReplicaSet en cree un nouveau automatiquement.

## Objectifs

- Deployer PostgreSQL dans un namespace dedie
- Gerer la configuration via ConfigMap et Secrets
- Mettre en place du stockage persistant (PV/PVC)
- Configurer les probes de sante (liveness/readiness)
- Comprendre les differentes methodes d'injection de variables d'environnement
- Tester la connexion a la base de donnees

## Prerequis

- Cluster Kubernetes fonctionnel (minikube recommande)
- `kubectl` installe et configure
- StorageClass disponible (verifier avec `kubectl get storageclass`)

## Architecture deployee

```
Cluster Kubernetes
+------------------------------------------------------------------+
|                                                                  |
|  Namespace: postgres                                             |
|  +------------------------------------------------------------+ |
|  |                                                            | |
|  |  +----------+   +-------------+   +--------------------+  | |
|  |  | ConfigMap|   | Secret      |   | PVC (8Gi)          |  | |
|  |  | credentials  | db-credentials  | storageClass:      |  | |
|  |  | POSTGRES_DB  | POSTGRES_USER   | standard           |  | |
|  |  | POSTGRES_USER| POSTGRES_PASS   +--------+-----------+  | |
|  |  | POSTGRES_PASS|               |          |              | |
|  |  +------+-------+  +------+----+          |              | |
|  |         |                  |               |              | |
|  |         v                  v               v              | |
|  |  +--------------------------------------------------+    | |
|  |  |  Deployment: postgresdb                          |    | |
|  |  |  +--------------------------------------------+  |    | |
|  |  |  | Pod                                        |  |    | |
|  |  |  |  postgres:latest                           |  |    | |
|  |  |  |  port: 5432                                |  |    | |
|  |  |  |  readinessProbe: pg_isready                |  |    | |
|  |  |  |  livenessProbe: pg_isready                 |  |    | |
|  |  |  |  mountPath: /var/lib/postgresql             |  |    | |
|  |  |  +--------------------------------------------+  |    | |
|  |  +--------------------------------------------------+    | |
|  |         ^                                                 | |
|  |         |  selector: app=postgresdb                       | |
|  |  +------+--------+                                        | |
|  |  | Service       |                                        | |
|  |  | ClusterIP     |                                        | |
|  |  | port: 5432    |                                        | |
|  |  +---------------+                                        | |
|  +------------------------------------------------------------+ |
|                                                                  |
|  PersistentVolume: pv (8Gi, hostPath: /data/db)                  |
+------------------------------------------------------------------+
```

## Fichiers et explication detaillee

### `namespace.yaml` -- Namespace dedie

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: postgres          # Namespace isole pour toute la stack PostgreSQL
```

Un namespace dedie pour isoler toutes les ressources PostgreSQL. Cela permet :
- D'appliquer des quotas de ressources (voir TP06)
- De definir des NetworkPolicies specifiques (voir TP05)
- De gerer les droits d'acces via RBAC (voir TP04)
- De supprimer facilement toutes les ressources avec `kubectl delete namespace postgres`

### `configmap.yaml` -- Configuration en clair

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  namespace: postgres
  name: credentials
  labels:
    app: postgresdb       # Label pour identifier la ressource
data:
  POSTGRES_DB: testdb           # Nom de la base creee au demarrage
  POSTGRES_USER: testuser       # Utilisateur cree au demarrage
  POSTGRES_PASSWORD: testpassword  # Mot de passe (en clair !)
```

**Champs importants :**
- `data` : chaque cle/valeur sera injectee comme variable d'environnement via `envFrom.configMapRef`.
- L'image officielle PostgreSQL utilise ces variables pour initialiser la base au **premier demarrage uniquement**. Si les donnees existent deja sur le volume, ces variables sont ignorees.
- **Attention** : ce ConfigMap contient un mot de passe en clair. Acceptable pour le developpement mais interdit en production. Utiliser un Secret a la place.

### `secret.yaml` -- Credentials encodes en Base64

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: db-credentials
  namespace: postgres
  labels:
    app: postgresdb
type: Opaque                       # Type generique pour des secrets arbitraires
data:
  POSTGRES_USER: dGVzdHVzZXI=     # echo -n "testuser" | base64
  POSTGRES_PASSWORD: czNjcjN0      # echo -n "s3cr3t" | base64
```

**Champs importants :**
- `type: Opaque` : type generique pour des secrets arbitraires. D'autres types existent :
  - `kubernetes.io/tls` pour les certificats TLS
  - `kubernetes.io/dockerconfigjson` pour les credentials de registre Docker
  - `kubernetes.io/basic-auth` pour l'authentification basique
- Les valeurs dans `data` doivent etre encodees en Base64. Pour generer : `echo -n "monmotdepasse" | base64` (le `-n` est **essentiel** pour ne pas inclure un retour a la ligne).
- On peut utiliser `stringData` au lieu de `data` pour fournir les valeurs en clair (Kubernetes les encode automatiquement au moment de l'application).
- Les Secrets sont stockes dans etcd. Par defaut, etcd ne chiffre pas les donnees au repos. Activer `EncryptionConfiguration` en production.

**Comment encoder/decoder en Base64 :**

```bash
# Encoder
echo -n "testuser" | base64
# Resultat : dGVzdHVzZXI=

# Decoder
echo "dGVzdHVzZXI=" | base64 -d
# Resultat : testuser

# Voir les secrets depuis le cluster (deja decodes)
kubectl get secret db-credentials -n postgres -o jsonpath='{.data.POSTGRES_USER}' | base64 -d
```

### `pv.yaml` -- PersistentVolume

```yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  name: pv
  labels:
    type: local
    app: postgresdb
spec:
  storageClassName: standard    # Doit matcher avec le PVC
  capacity:
    storage: 8Gi               # Capacite totale du volume (8 gibioctets)
  accessModes:
    - ReadWriteMany             # RWX : montable en R/W par plusieurs noeuds
  hostPath:
    path: "/data/db"            # Chemin sur le noeud hote
```

**Champs importants :**
- `storageClassName: standard` : identifie la classe de stockage. Sur **minikube**, la StorageClass par defaut est `standard`. Verifier avec `kubectl get storageclass`.
- `hostPath` : provisionne le stockage sur le systeme de fichiers du noeud. **Uniquement pour le developpement local** -- les donnees ne survivent pas si le Pod est replanifie sur un autre noeud.
- `ReadWriteMany` : dans un cluster multi-noeud, preferer `ReadWriteOnce` pour une base de donnees (un seul Pod ecrit a la fois).
- Le PV est une ressource **non-namespacee** (visible par tout le cluster), contrairement au PVC qui est namespacee.

### `pvc.yaml` -- PersistentVolumeClaim

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  namespace: postgres
  name: pvc
spec:
  storageClassName: standard    # Doit matcher le PV
  accessModes:
    - ReadWriteMany
  resources:
    requests:
      storage: 8Gi             # Taille demandee (<= capacite du PV)
```

**Champs importants :**
- Le PVC est le mecanisme par lequel un developpeur **demande du stockage** sans connaitre les details de l'infrastructure sous-jacente (le PV).
- Kubernetes cherche un PV compatible (meme storageClass, capacite suffisante, access mode compatible) et les lie automatiquement.
- Apres `kubectl apply`, verifier que le PVC est `Bound` : `kubectl get pvc -n postgres`.
- Si aucun PV compatible n'existe et qu'un provisioner dynamique est configure, le PV sera cree automatiquement.

### `deployment.yaml` -- Deployment principal (avec ConfigMap)

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  namespace: postgres
  name: postgresdb
spec:
  replicas: 1                   # Une seule instance (pas de HA)
  selector:
    matchLabels:
      app: postgresdb           # Doit matcher template.metadata.labels
  template:
    metadata:
      labels:
        app: postgresdb
    spec:
      containers:
        - name: postgresdb
          image: postgres:latest
          ports:
            - containerPort: 5432
          envFrom:
            - configMapRef:
                name: credentials    # Injecte TOUTES les cles du ConfigMap
          readinessProbe:
            exec:
              command: ["pg_isready", "-U", "testuser", "-d", "testdb"]
            initialDelaySeconds: 5    # Attend 5s apres le demarrage
            periodSeconds: 10         # Verifie toutes les 10s
            failureThreshold: 3       # 3 echecs = Pod NOT READY
          livenessProbe:
            exec:
              command: ["pg_isready", "-U", "testuser"]
            initialDelaySeconds: 30   # Attend 30s (PostgreSQL est lent a demarrer)
            periodSeconds: 20         # Verifie toutes les 20s
            failureThreshold: 3       # 3 echecs = restart du conteneur
          resources:
            limits:
              memory: "512Mi"
              cpu: "500m"
            requests:
              memory: "256Mi"
              cpu: "250m"
          volumeMounts:
            - mountPath: /var/lib/postgresql   # Repertoire des donnees PostgreSQL
              name: db-data
      volumes:
        - name: db-data
          persistentVolumeClaim:
            claimName: pvc
```

**Champs importants :**
- `envFrom.configMapRef` : injecte toutes les cles du ConfigMap comme variables d'environnement. Plus concis que de declarer chaque variable avec `env[].valueFrom.configMapKeyRef`.
- **readinessProbe** : utilise `pg_isready` (outil natif PostgreSQL) pour verifier que la base accepte les connexions. Le `-d testdb` verifie la disponibilite d'une base specifique. Tant que cette probe echoue, le Service ne route pas de trafic vers ce Pod.
- **livenessProbe** : le `initialDelaySeconds: 30` est plus long car PostgreSQL peut prendre du temps pour initialiser la base au premier demarrage. Si cette probe echoue 3 fois consecutives, le conteneur est tue et redemarre.
- **`mountPath: /var/lib/postgresql`** : pour les versions recentes de PostgreSQL, utiliser `/var/lib/postgresql` et **non** `/var/lib/postgresql/data`. L'image officielle initialise un sous-repertoire `data` automatiquement. Monter directement sur `/var/lib/postgresql/data` cause des erreurs d'initialisation car le repertoire n'est pas vide (il contient `lost+found` du systeme de fichiers).
- `resources` : les requests garantissent 256Mi et 250m CPU. Les limits empechent le conteneur de consommer plus de 512Mi et 500m CPU.

### Variantes de Deployment (dans `examples/`)

#### `examples/deployment-with-secret.yaml` -- Avec Secret via `envFrom`

La seule difference avec `deployment.yaml` est le remplacement de `configMapRef` par `secretRef` :

```yaml
envFrom:
  - secretRef:
      name: db-credentials    # Injecte les cles du Secret
```

Cette methode est **recommandee** pour les credentials : les valeurs sont decodees automatiquement du Base64 par Kubernetes avant injection dans le conteneur.

#### `examples/deployment-secret-volume.yaml` -- Avec Secret monte comme volume

```yaml
volumeMounts:
  - name: secret-volume
    mountPath: /etc/secrets   # Les secrets sont montes comme fichiers
    readOnly: true            # Lecture seule pour securite
  - name: db-data
    mountPath: /var/lib/postgresql
volumes:
  - name: secret-volume
    secret:
      secretName: db-credentials   # Chaque cle = un fichier
  - name: db-data
    persistentVolumeClaim:
      claimName: pvc
```

**Avantages du montage volume :**
- Chaque cle du Secret devient un fichier dans `/etc/secrets/` (ex: `/etc/secrets/POSTGRES_USER`).
- Les fichiers sont mis a jour automatiquement si le Secret change (sans redemarrer le Pod), avec un delai de propagation de quelques secondes.
- Ideal pour les certificats TLS et les fichiers de configuration sensibles.
- `readOnly: true` empeche le conteneur de modifier les secrets.

### `service.yaml` -- Service ClusterIP

```yaml
apiVersion: v1
kind: Service
metadata:
  name: postgresdb
  namespace: postgres
spec:
  type: ClusterIP       # Accessible uniquement depuis l'interieur du cluster
  selector:
    app: postgresdb     # Cible les Pods avec ce label
  ports:
    - port: 5432        # Port du service
      targetPort: 5432  # Port du conteneur
      protocol: TCP
```

**Champs importants :**
- `type: ClusterIP` : le service n'est accessible que depuis l'interieur du cluster. Contrairement au `LoadBalancer` du TP01, pas besoin d'acces externe pour une base de donnees.
- Les autres Pods du cluster peuvent y acceder via :
  - `postgresdb.postgres.svc.cluster.local:5432` (FQDN complet)
  - `postgresdb.postgres:5432` (depuis un autre namespace)
  - `postgresdb:5432` (depuis le meme namespace `postgres`)
- Pour acceder depuis votre machine, utiliser `kubectl port-forward`.

## Deploiement pas a pas

### 1. Creer le namespace

```bash
kubectl apply -f namespace.yaml
```

Sortie attendue :
```
namespace/postgres created
```

### 2. Verifier la StorageClass disponible

```bash
kubectl get storageclass
```

Sortie attendue sur minikube :
```
NAME                 PROVISIONER                RECLAIMPOLICY   VOLUMEBINDINGMODE   AGE
standard (default)   k8s.io/minikube-hostpath   Delete          Immediate           10d
```

### 3. Deployer la configuration

```bash
kubectl apply -f configmap.yaml
kubectl apply -f secret.yaml
```

Sortie attendue :
```
configmap/credentials created
secret/db-credentials created
```

Verifier que le ConfigMap et le Secret existent :
```bash
kubectl get configmap,secret -n postgres
```

### 4. Provisionner le stockage

```bash
kubectl apply -f pv.yaml
kubectl apply -f pvc.yaml
```

Verifier l'etat du PV et du PVC :
```bash
kubectl get pv,pvc -n postgres
```

Sortie attendue :
```
NAME                  CAPACITY   ACCESS MODES   RECLAIM POLICY   STATUS   CLAIM          STORAGECLASS
persistentvolume/pv   8Gi        RWX            Retain           Bound    postgres/pvc   standard

NAME                        STATUS   VOLUME   CAPACITY   ACCESS MODES   STORAGECLASS
persistentvolumeclaim/pvc   Bound    pv       8Gi        RWX            standard
```

Le STATUS doit etre **Bound** pour les deux. Si le PVC reste en `Pending`, voir la section Troubleshooting.

### 5. Deployer PostgreSQL (choisir UNE variante)

**Option A -- Avec ConfigMap (developpement) :**
```bash
kubectl apply -f deployment.yaml
```

**Option B -- Avec Secret via envFrom (recommande) :**
```bash
kubectl apply -f examples/deployment-with-secret.yaml
```

**Option C -- Avec Secret monte en volume (certificats, fichiers) :**
```bash
kubectl apply -f examples/deployment-secret-volume.yaml
```

### 6. Exposer le service

```bash
kubectl apply -f service.yaml
```

### 7. Verifier le deploiement complet

```bash
kubectl get all -n postgres
```

Sortie attendue :
```
NAME                              READY   STATUS    RESTARTS   AGE
pod/postgresdb-6f8b9c4d5-x7k2p   1/1     Running   0          45s

NAME                 TYPE        CLUSTER-IP      EXTERNAL-IP   PORT(S)    AGE
service/postgresdb   ClusterIP   10.96.123.45    <none>        5432/TCP   30s

NAME                         READY   UP-TO-DATE   AVAILABLE   AGE
deployment.apps/postgresdb   1/1     1            1           45s

NAME                                    DESIRED   CURRENT   READY   AGE
replicaset.apps/postgresdb-6f8b9c4d5   1         1         1       45s
```

Attendre que le Pod soit `Ready` :
```bash
kubectl wait --for=condition=Ready pods -l app=postgresdb -n postgres --timeout=120s
```

### 8. Tester la connexion a PostgreSQL

```bash
# Port-forward pour acceder localement
kubectl port-forward svc/postgresdb 15432:5432 -n postgres
```

Dans un **autre terminal** :
```bash
# Tester avec psql (si installe)
psql -h localhost -p 15432 -U testuser -d testdb

# OU tester avec un Pod temporaire directement dans le cluster
kubectl run -it --rm psql-test --image=postgres:latest -n postgres -- \
  psql -h postgresdb -U testuser -d testdb -c "SELECT version();"
```

### 9. Verifier les variables d'environnement injectees

```bash
# Remplacer <nom-du-pod> par le nom reel du Pod
kubectl exec -n postgres <nom-du-pod> -- env | grep POSTGRES
```

Sortie attendue (avec ConfigMap) :
```
POSTGRES_DB=testdb
POSTGRES_USER=testuser
POSTGRES_PASSWORD=testpassword
```

### 10. Verifier les probes

```bash
kubectl describe pod -l app=postgresdb -n postgres | grep -A5 "Readiness\|Liveness"
```

Sortie attendue :
```
    Liveness:   exec [pg_isready -U testuser] delay=30s timeout=1s period=20s #success=1 #failure=3
    Readiness:  exec [pg_isready -U testuser -d testdb] delay=5s timeout=1s period=10s #success=1 #failure=3
```

## Trois methodes d'injection des secrets -- resume

| Methode | Fichier | Avantage | Inconvenient |
|---------|---------|----------|--------------|
| ConfigMap (`envFrom`) | `deployment.yaml` | Simple, lisible | Valeurs en clair, non securise |
| Secret (`envFrom`) | `examples/deployment-with-secret.yaml` | Valeurs encodees, RBAC restreint | Figees au demarrage du Pod |
| Secret (volume) | `examples/deployment-secret-volume.yaml` | Mise a jour sans restart, ideal pour fichiers | Plus complexe a utiliser comme variables d'env |

## Exercice pratique

1. **Deployer la stack complete** avec le fichier `deployment.yaml` (option ConfigMap)
2. **Verifier** que le Pod est `Running` et `Ready` (1/1)
3. **Se connecter** a PostgreSQL via `port-forward` et executer `SELECT 1;`
4. **Supprimer le Pod** manuellement (`kubectl delete pod <nom> -n postgres`) et observer que le Deployment en recree un nouveau automatiquement
5. **Remplacer** le deployment par la variante Secret (`examples/deployment-with-secret.yaml`) et verifier que la connexion fonctionne toujours

## Points importants

- **mountPath** : utiliser `/var/lib/postgresql` (et non `/var/lib/postgresql/data`) avec les versions recentes de PostgreSQL. L'image officielle cree automatiquement le sous-repertoire `data` et echoue si le point de montage n'est pas vide.
- **StorageClass** : ce TP utilise `standard` qui est la StorageClass par defaut de minikube.
- **Secrets Base64** : l'encodage Base64 n'est PAS du chiffrement. En production, utiliser `EncryptionConfiguration` ou Vault (TP10).
- **Probes** : les arguments de `pg_isready` doivent correspondre aux valeurs reelles des variables d'environnement (utilisateur, nom de base).

## Troubleshooting

### Le PVC reste en `Pending`

**Cause probable** : pas de PV compatible (storageClass, capacite ou accessMode ne matchent pas).
```bash
kubectl describe pvc pvc -n postgres
# Chercher dans Events :
# "no persistent volumes available for this claim"
```
**Solution** : verifier que la storageClass du PV et du PVC correspondent. Verifier avec `kubectl get storageclass`.

### Le Pod est en `CrashLoopBackOff`

**Cause probable 1** : le mountPath est incorrect.
```bash
kubectl logs -l app=postgresdb -n postgres
# Si vous voyez "initdb: directory /var/lib/postgresql/data is not empty"
# => Le mountPath doit etre /var/lib/postgresql (pas /var/lib/postgresql/data)
```

**Cause probable 2** : les variables d'environnement sont manquantes.
```bash
kubectl exec -n postgres <nom-du-pod> -- env | grep POSTGRES
# Doit afficher POSTGRES_DB, POSTGRES_USER, POSTGRES_PASSWORD
```

**Cause probable 3** : le ConfigMap ou Secret reference n'existe pas.
```bash
kubectl describe pod -l app=postgresdb -n postgres
# Chercher dans Events :
# "Error: configmap 'credentials' not found"
```

### La readinessProbe echoue en boucle

**Cause probable** : l'utilisateur ou la base dans la commande `pg_isready` ne correspondent pas aux variables d'environnement.
```bash
kubectl describe pod -l app=postgresdb -n postgres | grep -A5 "Readiness\|Liveness"
```
**Solution** : les arguments de `pg_isready` doivent correspondre exactement aux valeurs du ConfigMap/Secret (ici `-U testuser -d testdb`).

### Erreur `Permission denied` sur le volume

**Cause probable** : PostgreSQL s'execute avec l'utilisateur `postgres` (UID 999) qui n'a pas les droits sur le volume.
```bash
# Verifier les permissions
kubectl exec -n postgres <nom-du-pod> -- ls -la /var/lib/postgresql
```
**Solution** : ajouter un `securityContext` avec `fsGroup: 999` dans la spec du Pod :
```yaml
spec:
  securityContext:
    fsGroup: 999
```

### Les donnees sont perdues apres un redemarrage du Pod

**Cause probable** : le volume n'est pas correctement monte ou le PVC n'est pas `Bound`.
```bash
kubectl get pvc -n postgres
# L'etat doit etre "Bound", pas "Pending"
```

### Le Service ne route pas le trafic

**Cause probable** : les labels du Pod ne matchent pas le selector du Service.
```bash
# Verifier les endpoints (doit lister l'IP du Pod)
kubectl get endpoints postgresdb -n postgres
# Si "none", le selector ne matche aucun Pod
```

## Commandes de debug

```bash
# Logs PostgreSQL
kubectl logs -l app=postgresdb -n postgres

# Logs en temps reel (follow)
kubectl logs -f -l app=postgresdb -n postgres

# Verifier les variables d'environnement injectees
kubectl exec -n postgres <nom-du-pod> -- env | grep POSTGRES

# Verifier les fichiers montes (variante volume)
kubectl exec -n postgres <nom-du-pod> -- ls /etc/secrets

# Lire un secret monte en fichier
kubectl exec -n postgres <nom-du-pod> -- cat /etc/secrets/POSTGRES_USER

# Events en cas de probleme (tries par date)
kubectl get events -n postgres --sort-by='.lastTimestamp'

# Verifier l'etat des probes
kubectl describe pod -l app=postgresdb -n postgres | grep -A5 "Readiness\|Liveness"

# Executer un shell dans le conteneur pour debugger
kubectl exec -it -n postgres <nom-du-pod> -- bash
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

## Pour aller plus loin

- [Documentation officielle Kubernetes : ConfigMaps](https://kubernetes.io/docs/concepts/configuration/configmap/)
- [Documentation officielle Kubernetes : Secrets](https://kubernetes.io/docs/concepts/configuration/secret/)
- [Documentation officielle Kubernetes : Persistent Volumes](https://kubernetes.io/docs/concepts/storage/persistent-volumes/)
- [Documentation officielle Kubernetes : Probes](https://kubernetes.io/docs/tasks/configure-pod-container/configure-liveness-readiness-startup-probes/)
- [Image Docker PostgreSQL officielle](https://hub.docker.com/_/postgres)
- [Encryption at rest dans Kubernetes](https://kubernetes.io/docs/tasks/administer-cluster/encrypt-data/)

**Suggestions d'amelioration :**
- Ajouter une `startupProbe` pour les cas ou PostgreSQL est tres lent a demarrer (grosses bases)
- Utiliser un `StatefulSet` au lieu d'un `Deployment` pour une identite stable (voir TP03)
- Implementer un backup automatique avec un CronJob (voir TP03)
- Utiliser un operateur PostgreSQL (CloudNativePG, Zalando Postgres Operator) pour la production
- Remplacer `hostPath` par un StorageClass avec provisioning dynamique
- Ajouter un `NetworkPolicy` pour restreindre l'acces au port 5432 (voir TP05)

## QCM de revision

**Question 1** : Quelle est la difference entre un ConfigMap et un Secret dans Kubernetes ?

- A) Un Secret est chiffre en AES-256, pas le ConfigMap
- B) Un Secret est encode en Base64 et peut etre chiffre au repos dans etcd, un ConfigMap stocke les donnees en clair
- C) Un Secret ne peut contenir que des mots de passe
- D) Il n'y a aucune difference technique, c'est une convention

<details>
<summary>Reponse</summary>
<b>B)</b> Les Secrets sont encodes en Base64 (pas chiffres par defaut !) et Kubernetes peut les chiffrer au repos dans etcd si <code>EncryptionConfiguration</code> est active. Les ConfigMaps stockent les donnees en texte brut. Les Secrets beneficient aussi de regles RBAC plus strictes par defaut.
</details>

---

**Question 2** : Que se passe-t-il quand la `readinessProbe` echoue ?

- A) Le conteneur est redemarre
- B) Le Pod est supprime
- C) Le Pod est retire des endpoints du Service (plus de trafic) mais n'est pas redemarre
- D) Rien, c'est juste informatif

<details>
<summary>Reponse</summary>
<b>C)</b> La readinessProbe controle le routage du trafic. Si elle echoue, le Pod est marque comme "Not Ready" et retire des endpoints du Service. Le conteneur continue de tourner et peut redevenir Ready si la probe reussit a nouveau. C'est la <b>livenessProbe</b> qui provoque un redemarrage.
</details>

---

**Question 3** : Pourquoi faut-il utiliser `mountPath: /var/lib/postgresql` et non `/var/lib/postgresql/data` pour les versions recentes de PostgreSQL ?

- A) Le repertoire `/data` n'existe plus dans les versions recentes
- B) L'image officielle cree automatiquement le sous-repertoire `data` et echoue si le point de montage contient deja des fichiers (comme `lost+found`)
- C) PostgreSQL stocke ses donnees a la racine du volume
- D) C'est un bug de l'image Docker

<details>
<summary>Reponse</summary>
<b>B)</b> Quand on monte un volume sur <code>/var/lib/postgresql/data</code>, le systeme de fichiers peut contenir <code>lost+found</code>, ce qui fait echouer <code>initdb</code> car le repertoire n'est pas vide. En montant sur <code>/var/lib/postgresql</code>, PostgreSQL cree lui-meme le sous-repertoire <code>data</code> proprement.
</details>

---

**Question 4** : Quel est l'avantage principal du montage d'un Secret comme volume par rapport a `envFrom` ?

- A) Le montage volume est plus rapide
- B) Les fichiers sont mis a jour automatiquement si le Secret change, sans redemarrer le Pod
- C) Le montage volume chiffre les donnees
- D) Les variables d'environnement ne supportent pas les caracteres speciaux

<details>
<summary>Reponse</summary>
<b>B)</b> Quand un Secret est monte comme volume, Kubernetes met a jour automatiquement les fichiers quand le Secret change (avec un delai de propagation). Avec <code>envFrom</code>, les variables d'environnement sont figees au demarrage du conteneur et ne sont pas mises a jour sans redemarrage.
</details>

---

**Question 5** : Quelle est la difference entre un PersistentVolume (PV) et un PersistentVolumeClaim (PVC) ?

- A) Le PV est cree par le developpeur, le PVC par l'administrateur
- B) Le PV represente le stockage physique provisionne, le PVC est une demande de stockage faite par le developpeur
- C) Le PV est namespacee, le PVC ne l'est pas
- D) Le PV est automatiquement supprime avec le namespace, pas le PVC

<details>
<summary>Reponse</summary>
<b>B)</b> Le PV (PersistentVolume) represente une ressource de stockage reelle provisionnee dans le cluster (par un administrateur ou un provisioner dynamique). Le PVC (PersistentVolumeClaim) est une <b>demande</b> de stockage faite par le developpeur. Kubernetes fait le lien (binding) automatiquement entre un PVC et un PV compatible. Le PV est non-namespacee (visible par tout le cluster), tandis que le PVC est namespacee.
</details>

---

**Question 6** : Que se passe-t-il si la `livenessProbe` echoue 3 fois consecutivement (avec `failureThreshold: 3`) ?

- A) Le Pod est retire des endpoints du Service
- B) Le Pod est supprime definitivement
- C) Le conteneur est tue et redemarre par kubelet
- D) Un alerte est envoyee a l'administrateur

<details>
<summary>Reponse</summary>
<b>C)</b> Quand la livenessProbe echoue au-dela du <code>failureThreshold</code>, kubelet tue le conteneur et le redemarre (selon la <code>restartPolicy</code>). Le compteur de restarts du Pod augmente. Cela se voit dans la colonne RESTARTS de <code>kubectl get pods</code>. Contrairement a la readinessProbe qui retire le trafic, la livenessProbe provoque un <b>redemarrage effectif</b> du conteneur.
</details>
