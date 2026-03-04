# TP07 - Helm -- Packaging d'une application PostgreSQL

## Introduction theorique

**Helm** est le **gestionnaire de paquets** de Kubernetes, souvent compare a `apt` pour Debian ou `brew` pour macOS. Il resout un probleme fondamental : quand une application necessite plusieurs fichiers YAML (Deployment, Service, PVC, ConfigMap, Secret...), les gerer un par un avec `kubectl apply` devient fastidieux, sujet aux erreurs, et difficile a reproduire entre environnements.

### Pourquoi Helm ?

Sans Helm, deployer une application PostgreSQL necessite :
```
kubectl apply -f namespace.yaml
kubectl apply -f pvc.yaml
kubectl apply -f configmap.yaml
kubectl apply -f secret.yaml
kubectl apply -f deployment.yaml
kubectl apply -f service.yaml
```

Chaque fichier contient des valeurs en dur (nom de la base, mot de passe, taille du stockage...). Pour deployer en production, il faut dupliquer tous les fichiers et modifier les valeurs. Helm resout cela avec le **templating** et les **values**.

### Les concepts cles de Helm

```
+------------------------------------------------------------------+
|                          Chart Helm                               |
|                                                                   |
|  Chart.yaml        Metadonnees (nom, version, description)       |
|  values.yaml       Valeurs par defaut (parametres)                |
|  templates/        Manifests Kubernetes avec du templating Go     |
|       |                                                           |
|       +-- deployment.yaml    {{ .Values.image.tag }}              |
|       +-- service.yaml       {{ .Values.service.port }}           |
|       +-- pvc.yaml           {{ .Values.storage.size }}           |
|       +-- _helpers.tpl       Fonctions reutilisables              |
|                                                                   |
+------------------------------------------------------------------+
         |                              |
         v                              v
  helm install                   helm upgrade -f values-prod.yaml
  (values par defaut)            (surcharge de production)
         |                              |
         v                              v
+------------------+           +------------------+
| Env DEV          |           | Env PROD         |
| image: postgres:16|          | image: postgres:16|
| db: testdb       |           | db: proddb       |
| cpu: 500m        |           | cpu: 2           |
| mem: 512Mi       |           | mem: 2Gi         |
+------------------+           +------------------+
```

**Chart** : un package Helm contenant tous les templates et la configuration par defaut. C'est l'equivalent d'un `.deb` ou d'un `.rpm`.

**Release** : une instance d'un chart installee dans un cluster. On peut installer le meme chart plusieurs fois avec des noms differents (ex: `postgresdb-dev`, `postgresdb-prod`).

**Values** : les parametres du chart. Le fichier `values.yaml` contient les valeurs par defaut, et on peut les surcharger avec `-f values-prod.yaml` ou `--set key=value`.

**Revision** : chaque `helm upgrade` cree une nouvelle revision. Helm conserve l'historique, ce qui permet de faire un `rollback` vers n'importe quelle version anterieure.

### Le templating Go

Helm utilise le moteur de templates de Go (package `text/template`). Les expressions entre `{{ }}` sont evaluees a l'installation et remplacees par les valeurs reelles.

```
Template                              Rendu final
-------------------------------       ---------------------------
image: "{{ .Values.image.tag }}"  --> image: "16"
name: {{ .Release.Name }}         --> name: postgresdb
namespace: {{ .Release.Namespace }}--> namespace: postgres
{{ .Values.env.POSTGRES_DB | quote }} --> "testdb"
{{- toYaml .Values.resources | nindent 12 }} --> limits:
                                                   cpu: 500m
                                                   memory: 512Mi
```

Les objets accessibles dans les templates :
- `.Values` : les valeurs du fichier `values.yaml` (ou surcharge)
- `.Release` : informations sur la release (Name, Namespace, Revision, IsInstall, IsUpgrade)
- `.Chart` : metadonnees du Chart.yaml (Name, Version, AppVersion)
- `.Capabilities` : informations sur le cluster (version de Kubernetes, APIs disponibles)

### Le cycle de vie d'une release

```
helm install        helm upgrade       helm upgrade        helm rollback
(revision 1)  --->  (revision 2)  ---> (revision 3)  --->  (revision 4)
values.yaml         values.yaml        values-prod.yaml    = copie de rev 2
  testdb              testdb             proddb              testdb
  500m CPU            500m CPU           2 CPU               500m CPU
```

Chaque operation (install, upgrade, rollback) cree une **nouvelle revision**. Le rollback ne "revient pas en arriere" : il cree une nouvelle revision avec le contenu d'une revision anterieure.

## Objectifs

- Comprendre la structure d'un chart Helm
- Creer un chart custom a partir de manifests existants
- Utiliser le templating Go pour parametrer les deploiements
- Gerer les revisions et les rollbacks
- Surcharger les values pour differents environnements

## Prerequis

- `helm` installe (`brew install helm` ou [documentation officielle](https://helm.sh/docs/intro/install/))
- Un cluster Kubernetes fonctionnel (minikube, Docker Desktop, etc.)
- `kubectl` installe et configure

```bash
# Verifier l'installation de Helm
helm version

# Sortie attendue (la version peut varier)
# version.BuildInfo{Version:"v3.x.x", ...}
```

## Architecture deployee

```
Cluster Kubernetes
+---------------------------------------------------------------------+
|                                                                     |
|  Namespace: postgres                                                |
|  +---------------------------------------------------------------+  |
|  |                                                               |  |
|  |  Release Helm: postgresdb (revision N)                        |  |
|  |                                                               |  |
|  |  +-------------------+         +------------------------+     |  |
|  |  | Service           |         | Deployment             |     |  |
|  |  | postgresdb        | selector| postgresdb             |     |  |
|  |  | ClusterIP         |-------->| replicas: 1            |     |  |
|  |  | port: 5432        |         | postgres:16            |     |  |
|  |  +-------------------+         | cpu: 250m-500m         |     |  |
|  |                                | mem: 256Mi-512Mi       |     |  |
|  |                                +----------+-------------+     |  |
|  |                                           |                   |  |
|  |                                     volumeMount               |  |
|  |                                  /var/lib/postgresql           |  |
|  |                                           |                   |  |
|  |                                +----------v-------------+     |  |
|  |                                | PVC                    |     |  |
|  |                                | postgresdb-pvc         |     |  |
|  |                                | storageClass: standard |     |  |
|  |                                | size: 8Gi              |     |  |
|  |                                +------------------------+     |  |
|  +---------------------------------------------------------------+  |
|                                                                     |
+---------------------------------------------------------------------+
```

## Structure du chart

```
postgresdb/
|-- Chart.yaml              # Metadonnees (nom, version, description)
|-- values.yaml             # Valeurs par defaut
|-- templates/
|   |-- _helpers.tpl        # Fonctions Go reutilisables
|   |-- deployment.yaml     # Template du Deployment
|   |-- service.yaml        # Template du Service
|   +-- pvc.yaml            # Template du PVC
values-prod.yaml            # Surcharge pour l'environnement de production
```

## Fichiers et explication detaillee

### `postgresdb/Chart.yaml` -- Metadonnees du chart

```yaml
apiVersion: v2                 # API Helm v3 (v1 pour Helm 2, deprecie)
name: postgresdb               # Nom du chart
description: Chart Helm pour le deploiement PostgreSQL du TP MIAGE
type: application              # "application" (deployable) ou "library" (dependance)
version: 0.1.0                 # Version du chart (semver, incrementee a chaque changement du chart)
appVersion: "16.0"             # Version de l'application empaquetee (PostgreSQL 16)
```

**Champs importants :**
- `apiVersion: v2` : indique un chart compatible Helm 3. La v1 etait utilisee par Helm 2, qui est deprecie depuis 2020.
- `version` : la version **du chart** (packaging). A incrementer a chaque modification des templates ou des values par defaut. Suit la convention SemVer (MAJOR.MINOR.PATCH).
- `appVersion` : la version **de l'application** empaquetee. Purement informative, elle n'affecte pas le comportement de Helm. Ici "16.0" correspond a PostgreSQL 16.
- `type: application` : un chart `application` cree des ressources Kubernetes. Un chart `library` ne contient que des helpers reutilisables par d'autres charts.

### `postgresdb/values.yaml` -- Valeurs par defaut

```yaml
replicaCount: 1                # Nombre de replicas du Deployment

image:
  repository: postgres         # Image Docker Hub
  tag: "16"                    # Tag de l'image
  pullPolicy: IfNotPresent     # Ne tire l'image que si elle n'est pas en cache

env:
  POSTGRES_DB: testdb          # Nom de la base de donnees
  POSTGRES_USER: testuser      # Utilisateur PostgreSQL
  POSTGRES_PASSWORD: testpassword  # Mot de passe (en clair -- pour le dev uniquement)

service:
  type: ClusterIP              # Type de service (interne au cluster)
  port: 5432                   # Port PostgreSQL standard

storage:
  storageClass: standard       # StorageClass minikube par defaut
  size: 8Gi                    # Taille du volume persistant
  mountPath: /var/lib/postgresql  # Point de montage dans le conteneur

resources:
  limits:
    cpu: 500m                  # Maximum : 0.5 CPU
    memory: 512Mi              # Maximum : 512 Mo
  requests:
    cpu: 250m                  # Garanti : 0.25 CPU
    memory: 256Mi              # Garanti : 256 Mo
```

**Champs importants :**
- Chaque valeur est accessible dans les templates via `.Values.<chemin>`. Par exemple, `.Values.image.tag` vaut `"16"`.
- `pullPolicy: IfNotPresent` : Kubernetes ne re-telecharge l'image que si elle n'est pas deja presente sur le noeud. Utile pour le developpement local. En production, utiliser `Always` avec un tag fixe pour s'assurer d'avoir la derniere version.
- `storageClass: standard` : **a adapter selon votre cluster** :
  - `standard` pour minikube (StorageClass par defaut avec provisioner `k8s.io/minikube-hostpath`)
  - `hostpath` pour Docker Desktop (StorageClass par defaut avec provisioner `docker.io/hostpath`)
  - `gp2` ou `gp3` pour AWS EKS
  - `standard-rwo` pour GKE
- Les credentials en clair dans `values.yaml` sont acceptables pour le dev/TP mais inacceptables en production. En production, utiliser des Secrets Kubernetes ou un gestionnaire de secrets (Vault, etc.).

### `values-prod.yaml` -- Surcharge pour la production

```yaml
env:
  POSTGRES_DB: proddb          # Base de donnees de production
  POSTGRES_USER: produser      # Utilisateur de production
  POSTGRES_PASSWORD: supersecret  # Mot de passe de production

resources:
  limits:
    cpu: "2"                   # 2 CPU max (4x plus qu'en dev)
    memory: 2Gi                # 2 Go max (4x plus qu'en dev)
  requests:
    cpu: 500m                  # 0.5 CPU garanti (2x plus qu'en dev)
    memory: 512Mi              # 512 Mo garanti (2x plus qu'en dev)
```

**Champs importants :**
- Ce fichier ne contient que les valeurs qui **different** de `values.yaml`. Toutes les autres valeurs (replicaCount, image, service, storage) gardent leurs valeurs par defaut.
- Helm fusionne (merge) les values : `values-prod.yaml` ecrase uniquement les cles qu'il definit. C'est un merge profond (deep merge).
- On peut empiler plusieurs fichiers de values : `helm upgrade -f values-prod.yaml -f values-secrets.yaml`. Le dernier fichier a la priorite.

### `postgresdb/templates/_helpers.tpl` -- Fonctions reutilisables

```go
{{/*
Nom complet du chart
*/}}
{{- define "postgresdb.fullname" -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Labels standards
*/}}
{{- define "postgresdb.labels" -}}
app: {{ .Release.Name }}
chart: {{ .Chart.Name }}-{{ .Chart.Version }}
release: {{ .Release.Name }}
{{- end }}
```

**Champs importants :**
- `{{- define "postgresdb.fullname" -}}` : definit un template nomme reutilisable avec `{{ include "postgresdb.fullname" . }}`.
- `trunc 63` : tronque le nom a 63 caracteres, la limite imposee par Kubernetes pour les noms de ressources (conforme au DNS RFC 1123).
- `trimSuffix "-"` : retire un tiret final eventuel apres la troncature.
- Les labels standards permettent d'identifier la release Helm, le chart et sa version. Utile pour le filtrage et le debugging.

### `postgresdb/templates/deployment.yaml` -- Template du Deployment

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ .Release.Name }}              # Nom dynamique = nom de la release
  namespace: {{ .Release.Namespace }}    # Namespace cible
  labels:
    app: {{ .Release.Name }}
spec:
  replicas: {{ .Values.replicaCount }}   # Nombre de replicas parametre
  selector:
    matchLabels:
      app: {{ .Release.Name }}
  template:
    metadata:
      labels:
        app: {{ .Release.Name }}
    spec:
      containers:
        - name: postgresdb
          image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
          imagePullPolicy: {{ .Values.image.pullPolicy }}
          ports:
            - containerPort: 5432
          env:
            - name: POSTGRES_DB
              value: {{ .Values.env.POSTGRES_DB | quote }}     # | quote ajoute les guillemets
            - name: POSTGRES_USER
              value: {{ .Values.env.POSTGRES_USER | quote }}
            - name: POSTGRES_PASSWORD
              value: {{ .Values.env.POSTGRES_PASSWORD | quote }}
          resources:
            {{- toYaml .Values.resources | nindent 12 }}       # Conversion YAML avec indentation
          volumeMounts:
            - name: data
              mountPath: {{ .Values.storage.mountPath }}
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: {{ .Release.Name }}-pvc
```

**Champs importants :**
- `{{ .Release.Name }}` : utilise le nom de la release Helm comme nom de toutes les ressources. Cela permet d'installer plusieurs instances du meme chart sans conflit de noms.
- `{{ .Values.env.POSTGRES_DB | quote }}` : le pipe `| quote` entoure la valeur de guillemets doubles. Indispensable pour les valeurs YAML qui pourraient etre interpretees comme des nombres ou des booleens (ex: `"true"`, `"123"`).
- `{{- toYaml .Values.resources | nindent 12 }}` : convertit l'objet Go en YAML et l'indente de 12 espaces. Le tiret `{{-` supprime les espaces blancs avant l'expression pour eviter les lignes vides.
- `claimName: {{ .Release.Name }}-pvc` : le PVC porte le nom de la release suivi de `-pvc`, ce qui le lie au template `pvc.yaml`.

### `postgresdb/templates/service.yaml` -- Template du Service

```yaml
apiVersion: v1
kind: Service
metadata:
  name: {{ .Release.Name }}
  namespace: {{ .Release.Namespace }}
spec:
  type: {{ .Values.service.type }}        # ClusterIP par defaut
  ports:
    - port: {{ .Values.service.port }}    # Port du service (5432)
      targetPort: 5432                     # Port du conteneur PostgreSQL
  selector:
    app: {{ .Release.Name }}               # Cible les Pods de la release
```

**Champs importants :**
- `type: ClusterIP` (valeur par defaut) : le service n'est accessible qu'a l'interieur du cluster. Pour un acces externe, surcharger avec `--set service.type=NodePort` ou modifier dans un fichier de values.
- Le `selector` utilise `app: {{ .Release.Name }}` pour cibler les Pods du Deployment de la meme release.
- Le DNS interne du service sera : `postgresdb.postgres.svc.cluster.local:5432`.

### `postgresdb/templates/pvc.yaml` -- Template du PVC

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: {{ .Release.Name }}-pvc
  namespace: {{ .Release.Namespace }}
spec:
  storageClassName: {{ .Values.storage.storageClass }}  # standard (minikube)
  accessModes:
    - ReadWriteOnce                                      # Un seul noeud en ecriture
  resources:
    requests:
      storage: {{ .Values.storage.size }}                # 8Gi par defaut
```

**Champs importants :**
- `storageClassName: standard` : sur minikube, le provisioner par defaut cree des volumes `hostPath`. La StorageClass `standard` est creee automatiquement par minikube.
- `ReadWriteOnce` (RWO) : le volume ne peut etre monte en ecriture que par un seul noeud. C'est le mode standard pour les bases de donnees (un seul Pod ecrit).
- Le PVC est nomme `{{ .Release.Name }}-pvc` pour correspondre au `claimName` reference dans le Deployment.

## Deploiement pas a pas

### 1. Valider le chart avec lint

```bash
helm lint ./postgresdb
```

Sortie attendue :
```
==> Linting ./postgresdb
[INFO] Chart.yaml: icon is recommended

1 chart(s) linted, 0 chart(s) failed
```

> `helm lint` verifie la syntaxe du Chart.yaml, la validite des templates et la coherence des values. Un warning "icon is recommended" est normal (l'icone est optionnelle).

### 2. Previsualiser les manifests generes

```bash
helm template postgresdb ./postgresdb --namespace postgres
```

Cette commande affiche les manifests YAML generes **sans rien appliquer** au cluster. Utile pour verifier que le templating produit le YAML attendu.

Sortie attendue (extrait) :
```yaml
---
# Source: postgresdb/templates/pvc.yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: postgresdb-pvc
  namespace: postgres
spec:
  storageClassName: standard
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 8Gi
---
# Source: postgresdb/templates/service.yaml
apiVersion: v1
kind: Service
metadata:
  name: postgresdb
  namespace: postgres
spec:
  type: ClusterIP
  ports:
    - port: 5432
      targetPort: 5432
  selector:
    app: postgresdb
---
# Source: postgresdb/templates/deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: postgresdb
  namespace: postgres
...
```

### 3. Dry-run complet (validation cote serveur)

```bash
helm install postgresdb ./postgresdb \
  -n postgres --create-namespace --dry-run --debug
```

A la difference de `helm template`, le `--dry-run` envoie les manifests a l'API Server Kubernetes pour validation sans les appliquer. Cela detecte les erreurs de schema, les conflits de noms, etc.

### 4. Installer la release

```bash
helm upgrade --install postgresdb ./postgresdb \
  -n postgres --create-namespace
```

Sortie attendue :
```
Release "postgresdb" does not exist. Installing it now.
NAME: postgresdb
LAST DEPLOYED: ...
NAMESPACE: postgres
STATUS: deployed
REVISION: 1
```

**Explication de `upgrade --install`** : cette commande est **idempotente**. Si la release n'existe pas, elle l'installe. Si elle existe deja, elle la met a jour. C'est la commande recommandee dans les pipelines CI/CD car elle evite de gerer les cas "premiere installation" vs "mise a jour".

### 5. Verifier le deploiement

```bash
# Statut de la release Helm
helm status postgresdb -n postgres

# Ressources creees dans le namespace
kubectl get all -n postgres

# Verifier le PVC
kubectl get pvc -n postgres
```

Sortie attendue pour `kubectl get all` :
```
NAME                              READY   STATUS    RESTARTS   AGE
pod/postgresdb-xxxxxxxxxx-xxxxx   1/1     Running   0          30s

NAME                 TYPE        CLUSTER-IP     EXTERNAL-IP   PORT(S)    AGE
service/postgresdb   ClusterIP   10.96.xxx.xx   <none>        5432/TCP   30s

NAME                         READY   UP-TO-DATE   AVAILABLE   AGE
deployment.apps/postgresdb   1/1     1            1           30s

NAME                                    DESIRED   CURRENT   READY   AGE
replicaset.apps/postgresdb-xxxxxxxxxx   1         1         1       30s
```

```bash
# Values appliquees
helm get values postgresdb -n postgres

# Manifests rendus (YAML reel applique au cluster)
helm get manifest postgresdb -n postgres
```

### 6. Tester la connexion a PostgreSQL

```bash
# Port-forward pour acceder a PostgreSQL depuis la machine locale
kubectl port-forward svc/postgresdb 5432:5432 -n postgres

# Dans un autre terminal, se connecter avec psql (si installe)
psql -h localhost -p 5432 -U testuser -d testdb
```

### 7. Mettre a jour avec les values de production

```bash
helm upgrade postgresdb ./postgresdb \
  -f values-prod.yaml -n postgres
```

Sortie attendue :
```
Release "postgresdb" has been upgraded. Happy Helming!
NAME: postgresdb
LAST DEPLOYED: ...
NAMESPACE: postgres
STATUS: deployed
REVISION: 2
```

Verifier les nouvelles values :
```bash
helm get values postgresdb -n postgres
```

Sortie attendue :
```
USER-SUPPLIED VALUES:
env:
  POSTGRES_DB: proddb
  POSTGRES_USER: produser
  POSTGRES_PASSWORD: supersecret
resources:
  limits:
    cpu: "2"
    memory: 2Gi
  requests:
    cpu: 500m
    memory: 512Mi
```

### 8. Historique et rollback

```bash
# Voir l'historique des revisions
helm history postgresdb -n postgres
```

Sortie attendue :
```
REVISION  UPDATED                   STATUS      CHART              APP VERSION  DESCRIPTION
1         ...                       superseded  postgresdb-0.1.0   16.0         Install complete
2         ...                       deployed    postgresdb-0.1.0   16.0         Upgrade complete
```

```bash
# Rollback a la revision 1 (values de dev)
helm rollback postgresdb 1 -n postgres
```

Sortie attendue :
```
Rollback was a success! Happy Helming!
```

```bash
# Verifier : une revision 3 a ete creee (copie de la revision 1)
helm history postgresdb -n postgres
```

Sortie attendue :
```
REVISION  UPDATED                   STATUS      CHART              APP VERSION  DESCRIPTION
1         ...                       superseded  postgresdb-0.1.0   16.0         Install complete
2         ...                       superseded  postgresdb-0.1.0   16.0         Upgrade complete
3         ...                       deployed    postgresdb-0.1.0   16.0         Rollback to 1
```

## Syntaxe Go templating -- Aide-memoire

| Expression | Description | Exemple de rendu |
|-----------|-------------|------------------|
| `{{ .Release.Name }}` | Nom de la release Helm | `postgresdb` |
| `{{ .Release.Namespace }}` | Namespace cible | `postgres` |
| `{{ .Release.Revision }}` | Numero de revision | `2` |
| `{{ .Chart.Name }}` | Nom du chart | `postgresdb` |
| `{{ .Chart.Version }}` | Version du chart | `0.1.0` |
| `{{ .Values.image.tag }}` | Valeur depuis values.yaml | `16` |
| `{{ .Values.env.POSTGRES_DB \| quote }}` | Valeur entre guillemets | `"testdb"` |
| `{{- toYaml .Values.resources \| nindent 12 }}` | Objet Go vers YAML indente | bloc YAML a 12 espaces |
| `{{ include "postgresdb.fullname" . }}` | Appel d'un helper | `postgresdb` |
| `{{ if .Values.storage.enabled }}...{{ end }}` | Conditionnel | bloc inclus ou omis |
| `{{ range .Values.env }}...{{ end }}` | Boucle sur une liste | repete le bloc |
| `{{ default "latest" .Values.image.tag }}` | Valeur par defaut | `16` (ou `latest` si absent) |

**Fonctions utiles :**
- `quote` : entoure de guillemets (`"valeur"`)
- `upper` / `lower` : majuscules / minuscules
- `trim` : supprime les espaces en debut et fin
- `nindent N` : ajoute un retour a la ligne + N espaces d'indentation
- `indent N` : ajoute N espaces d'indentation (sans retour a la ligne)
- `toYaml` : convertit un objet Go en YAML
- `default` : valeur de repli si la valeur est vide/absente

## Commandes Helm essentielles

| Commande | Description |
|----------|-------------|
| `helm lint ./chart` | Verifie la syntaxe du chart |
| `helm template <name> ./chart` | Affiche les manifests sans appliquer |
| `helm install <name> ./chart` | Installe une release |
| `helm upgrade --install <name> ./chart` | Install ou upgrade (idempotent) |
| `helm upgrade <name> ./chart -f values.yaml` | Upgrade avec surcharge de values |
| `helm list -n <ns>` | Liste les releases d'un namespace |
| `helm status <name> -n <ns>` | Detail d'une release |
| `helm get values <name> -n <ns>` | Affiche les values appliquees |
| `helm get manifest <name> -n <ns>` | Affiche les manifests rendus |
| `helm history <name> -n <ns>` | Historique des revisions |
| `helm rollback <name> [revision] -n <ns>` | Retour a une version anterieure |
| `helm uninstall <name> -n <ns>` | Supprime la release et ses ressources |
| `helm show values ./chart` | Affiche les values par defaut du chart |
| `helm repo add <name> <url>` | Ajoute un depot de charts |
| `helm search repo <keyword>` | Cherche un chart dans les depots |

## Troubleshooting

### `helm lint` retourne des erreurs de template

**Cause** : syntaxe Go invalide dans un fichier template (accolade manquante, variable inexistante).
```bash
helm lint ./postgresdb --debug
# Le flag --debug affiche le detail des erreurs
```
**Solution** : verifier les `{{ }}` dans les templates. Les erreurs courantes sont les espaces manquants (`{{.Values}}` au lieu de `{{ .Values }}`) et les chemins de values incorrects.

### `Error: INSTALLATION FAILED: cannot re-use a name that is still in use`

**Cause** : une release avec ce nom existe deja dans le namespace.
```bash
helm list -n postgres
```
**Solution** : utiliser `helm upgrade --install` au lieu de `helm install`, ou desinstaller d'abord avec `helm uninstall postgresdb -n postgres`.

### Le Pod PostgreSQL est en `CrashLoopBackOff`

**Cause probable** : les variables d'environnement sont mal injectees (absence de `POSTGRES_PASSWORD`).
```bash
kubectl logs -n postgres deployment/postgresdb
kubectl describe pod -n postgres -l app=postgresdb
```
**Solution** : verifier que les values `env.POSTGRES_PASSWORD` sont definies et que le template utilise `| quote` pour les valeurs.

### Le PVC reste en `Pending`

**Cause** : la StorageClass n'existe pas ou le provisioner ne peut pas creer le volume.
```bash
kubectl get pvc -n postgres
kubectl describe pvc postgresdb-pvc -n postgres
kubectl get storageclass
```
**Solution** : verifier que la StorageClass existe et adapter si necessaire :
```bash
kubectl get storageclass

# Sur minikube : la StorageClass est "standard"
helm upgrade --install postgresdb ./postgresdb --set storage.storageClass=standard -n postgres

# Sur Docker Desktop : la StorageClass est "hostpath"
helm upgrade --install postgresdb ./postgresdb --set storage.storageClass=hostpath -n postgres
```

### `helm rollback` ne restaure pas les donnees

**Cause** : Helm ne gere que les **manifests Kubernetes**, pas les **donnees** dans les volumes. Un rollback reapplique les anciens manifests (ancien mot de passe, anciennes resources) mais ne touche pas au contenu du PVC.
**Solution** : pour restaurer les donnees, utiliser un backup PostgreSQL (pg_dump/pg_restore).

### Les values de production ne s'appliquent pas

**Cause** : le chemin vers le fichier de surcharge est incorrect ou le fichier est mal formate.
```bash
# Verifier avec template avant d'appliquer
helm template postgresdb ./postgresdb -f values-prod.yaml -n postgres
# Comparer la sortie avec les values attendues
```
**Solution** : verifier que le fichier `values-prod.yaml` est a la racine du TP (pas dans le dossier `postgresdb/`) et que l'indentation YAML est correcte.

### Erreur "Error: UPGRADE FAILED: current release manifest contains removed resource"

**Cause** : un template a ete supprime ou renomme entre deux revisions.
```bash
helm history postgresdb -n postgres
```
**Solution** : verifier les templates modifies. Si necessaire, `helm uninstall` puis `helm install` pour repartir proprement.

## Nettoyage

```bash
helm uninstall postgresdb -n postgres
kubectl delete namespace postgres
```

> **Attention** : `helm uninstall` supprime toutes les ressources gerees par la release, y compris le PVC. Les donnees PostgreSQL seront **perdues**. Pour conserver le PVC, utiliser `helm uninstall --keep-history` et supprimer manuellement les ressources sauf le PVC.

## Pour aller plus loin

- [Documentation officielle Helm](https://helm.sh/docs/)
- [Guide des bonnes pratiques Helm](https://helm.sh/docs/chart_best_practices/)
- [Go Template Documentation](https://pkg.go.dev/text/template)
- [Artifact Hub - Depot public de charts](https://artifacthub.io/)
- [Chart Bitnami PostgreSQL](https://artifacthub.io/packages/helm/bitnami/postgresql) -- un chart production-ready complet

**Suggestions d'amelioration :**
- Ajouter un template `secret.yaml` pour gerer les credentials avec des Secrets Kubernetes au lieu de variables d'environnement en clair
- Ajouter des `livenessProbe` et `readinessProbe` dans le Deployment pour la sante du conteneur
- Utiliser `{{ include "postgresdb.labels" . }}` dans tous les templates pour des labels coherents
- Ajouter un template `NOTES.txt` qui affiche les instructions de connexion apres l'installation
- Explorer les **Helm hooks** (pre-install, post-install) pour initialiser la base de donnees
- Publier le chart dans un depot Helm (ChartMuseum, GitHub Pages, OCI registry)
- Comparer avec le chart Bitnami PostgreSQL pour decouvrir les patterns de production (initContainers, sidecar pgBouncer, backup CronJob)

## QCM de revision

**Question 1** : Quelle est la difference entre `helm template` et `helm install --dry-run` ?

- A) Ils sont identiques
- B) `helm template` genere le YAML localement, `--dry-run` envoie les manifests a l'API Server pour validation
- C) `helm template` installe les ressources, `--dry-run` ne fait que verifier
- D) `helm template` est pour la production, `--dry-run` pour le dev

<details>
<summary>Reponse</summary>
<b>B)</b> <code>helm template</code> effectue le rendu des templates <b>localement</b> sans contacter le cluster. <code>helm install --dry-run</code> envoie les manifests generes a l'<b>API Server</b> pour validation (verification des schemas, des quotas, etc.) sans creer les ressources. Le dry-run detecte donc plus d'erreurs.
</details>

---

**Question 2** : Que fait la commande `helm upgrade --install` ?

- A) Elle ecrase toujours la release existante
- B) Elle installe la release si elle n'existe pas, sinon elle la met a jour
- C) Elle installe une deuxieme instance de la release
- D) Elle met a jour uniquement les values sans toucher aux templates

<details>
<summary>Reponse</summary>
<b>B)</b> <code>helm upgrade --install</code> est <b>idempotente</b>. Si la release n'existe pas, elle se comporte comme <code>helm install</code>. Si elle existe deja, elle se comporte comme <code>helm upgrade</code>. C'est la commande recommandee dans les pipelines CI/CD.
</details>

---

**Question 3** : Que se passe-t-il quand on execute `helm rollback postgresdb 1` ?

- A) La revision 1 est restauree et la revision 2 est supprimee
- B) Une nouvelle revision (3) est creee avec le contenu de la revision 1
- C) Le cluster revient a l'etat exact de la revision 1, y compris les donnees
- D) La commande echoue car on ne peut pas revenir en arriere

<details>
<summary>Reponse</summary>
<b>B)</b> Le rollback cree une <b>nouvelle revision</b> (numero 3) dont le contenu est identique a celui de la revision 1. L'historique est <b>preserve</b> : les revisions 1 et 2 restent visibles dans <code>helm history</code>. Les donnees dans les volumes ne sont <b>pas</b> affectees.
</details>

---

**Question 4** : A quoi sert le pipe `| quote` dans `{{ .Values.env.POSTGRES_DB | quote }}` ?

- A) Il chiffre la valeur
- B) Il entoure la valeur de guillemets doubles dans le YAML genere
- C) Il encode la valeur en Base64
- D) Il valide que la valeur est une chaine de caracteres

<details>
<summary>Reponse</summary>
<b>B)</b> Le pipe <code>| quote</code> entoure la valeur de <b>guillemets doubles</b>. C'est important pour les valeurs YAML qui pourraient etre interpretees comme des nombres (<code>123</code>), des booleens (<code>true</code>/<code>false</code>) ou des valeurs speciales (<code>null</code>). Avec <code>| quote</code>, la valeur est toujours traitee comme une chaine.
</details>

---

**Question 5** : Quelle est la difference entre `version` et `appVersion` dans Chart.yaml ?

- A) `version` est la version de Helm, `appVersion` est la version de Kubernetes
- B) `version` est la version du chart (packaging), `appVersion` est la version de l'application empaquetee
- C) Ce sont deux synonymes
- D) `version` est obligatoire, `appVersion` est interdit

<details>
<summary>Reponse</summary>
<b>B)</b> <code>version</code> est la version <b>du chart</b> lui-meme (packaging). Elle doit etre incrementee a chaque modification des templates ou des values par defaut. <code>appVersion</code> est la version de l'<b>application</b> empaquetee (ici PostgreSQL 16.0). Elle est purement informative et n'affecte pas le comportement de Helm.
</details>

---

**Question 6** : Comment Helm fusionne-t-il les values quand on utilise `-f values-prod.yaml` ?

- A) Il remplace entierement values.yaml par values-prod.yaml
- B) Il fait un merge profond : les cles de values-prod.yaml ecrasent celles de values.yaml, les autres sont conservees
- C) Il concatene les deux fichiers
- D) Il n'utilise que values-prod.yaml et ignore values.yaml

<details>
<summary>Reponse</summary>
<b>B)</b> Helm effectue un <b>deep merge</b> (fusion profonde). Les cles presentes dans <code>values-prod.yaml</code> ecrasent les cles correspondantes de <code>values.yaml</code>. Les cles absentes de <code>values-prod.yaml</code> conservent leurs valeurs par defaut. Par exemple, <code>replicaCount</code> et <code>image</code> ne sont pas dans values-prod.yaml, ils gardent donc les valeurs de values.yaml.
</details>

---

**Question 7** : Pourquoi utiliser `{{- toYaml .Values.resources | nindent 12 }}` au lieu d'ecrire les resources directement ?

- A) C'est obligatoire pour Helm
- B) Cela permet de parametrer les resources via les values sans modifier le template
- C) C'est plus performant
- D) Cela chiffre les valeurs

<details>
<summary>Reponse</summary>
<b>B)</b> <code>toYaml</code> convertit l'objet Go <code>.Values.resources</code> en YAML valide, et <code>nindent 12</code> l'indente correctement. Cela permet de <b>parametrer</b> les resources (CPU, memoire) via les values sans toucher au template. Chaque environnement (dev, prod) peut avoir ses propres limites simplement en changeant le fichier de values.
</details>
