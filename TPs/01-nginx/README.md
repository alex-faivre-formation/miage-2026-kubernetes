# TP01 - Deploiement d'un conteneur Nginx

## Introduction theorique

Ce premier TP introduit les concepts fondamentaux de Kubernetes a travers le deploiement d'un serveur web Nginx. Nous allons manipuler les briques de base de tout deploiement Kubernetes : le **Pod**, le **Namespace**, le **Service**, les **Labels/Selectors** et la gestion des **ressources** (CPU/memoire).

### Qu'est-ce qu'un Pod ?

Le Pod est la plus petite unite deployable dans Kubernetes. Contrairement a Docker ou l'on manipule des conteneurs individuels, Kubernetes regroupe un ou plusieurs conteneurs dans un Pod. Tous les conteneurs d'un meme Pod partagent :

- Le meme espace reseau (meme adresse IP, meme `localhost`)
- Les memes volumes montes
- Le meme cycle de vie (ils demarrent et s'arretent ensemble)

```
+---------------------------+
|         Pod nginx         |
|  +---------------------+ |
|  |  Conteneur nginx    | |
|  |  - Image: nginx     | |
|  |  - Port: 80         | |
|  +---------------------+ |
|  IP: 10.244.0.5          |
+---------------------------+
```

### Qu'est-ce qu'un Namespace ?

Un Namespace est une **isolation logique** des ressources Kubernetes. Il permet de separer les environnements (dev, staging, prod) ou les equipes sur un meme cluster. Chaque namespace possede son propre espace de noms pour les ressources : deux Pods de meme nom peuvent coexister dans deux namespaces differents.

Par defaut, Kubernetes cree les namespaces `default`, `kube-system`, `kube-public` et `kube-node-lease`.

### Qu'est-ce qu'un Service ?

Un Service fournit une **adresse stable** pour acceder a un ensemble de Pods. Les Pods etant ephemeres (ils peuvent etre recrees a tout moment avec une nouvelle IP), le Service agit comme un load balancer interne qui detecte automatiquement les Pods cibles grace aux **Labels/Selectors**.

```
                    +------------------+
                    |   Service        |
 Client  --------> |   nginx-service  |
                    |   Type: LB       |
                    |   Port: 80       |
                    +--------|---------+
                             |  selector: app=nginx
                             v
                    +------------------+
                    |   Pod nginx      |
                    |   label: app=nginx|
                    |   Port: 80       |
                    +------------------+
```

### Labels et Selectors

Les Labels sont des paires cle/valeur attachees aux objets Kubernetes. Ils constituent le **mecanisme central de liaison** entre les ressources. Un Service trouve ses Pods cibles grace a un `selector` qui filtre les Pods par leurs labels.

### Requests et Limits

Kubernetes permet de controler la consommation de ressources de chaque conteneur :

- **requests** : quantite de CPU/memoire **garantie** au conteneur. Le scheduler utilise cette valeur pour placer le Pod sur un noeud disposant de suffisamment de ressources.
- **limits** : quantite **maximale** que le conteneur peut consommer. Si le conteneur depasse la limit memoire, il est tue (OOMKilled). Si il depasse la limit CPU, il est throttled (ralenti).

```
  requests          limits
  (garanti)         (maximum)
     |                 |
     v                 v
  |--[====CPU=====]----|--------->
  0  250m          500m
```

## Objectifs

- Creer un namespace Kubernetes
- Deployer un pod Nginx avec des contraintes de ressources
- Exposer le pod via un Service LoadBalancer
- Comprendre les labels et selectors
- (Optionnel) Deployer une stack PostgreSQL dans le meme namespace

## Prerequis

- Un cluster Kubernetes fonctionnel (minikube, Docker Desktop, etc.)
- `kubectl` installe et configure

## Architecture deployee

```
Cluster Kubernetes
+-------------------------------------------------------------+
|                                                             |
|  Namespace: nginx                                           |
|  +-------------------------------------------------------+ |
|  |                                                       | |
|  |  +-------------+    selector     +------------------+ | |
|  |  | Service     |  app=nginx      | Pod nginx        | | |
|  |  | LoadBalancer|  ------------->  | nginx:latest     | | |
|  |  | port: 80    |                 | containerPort:80 | | |
|  |  +-------------+                 | cpu: 250m-500m   | | |
|  |                                  | mem: 128Mi-256Mi | | |
|  |                                  +------------------+ | |
|  |                                                       | |
|  |  (Optionnel) Stack PostgreSQL :                       | |
|  |  ConfigMap + Secret + PV/PVC + Deployment             | |
|  +-------------------------------------------------------+ |
|                                                             |
|  Namespace: neuvector (vide, cree pour usage futur)         |
|                                                             |
+-------------------------------------------------------------+
```

## Fichiers et explication detaillee

### `namespaces.yml` -- Creation des namespaces

```yaml
apiVersion: v1          # API core de Kubernetes (ressources de base)
kind: Namespace         # Type de ressource
metadata:
  name: nginx           # Nom du namespace -- sera utilise avec -n nginx
---
apiVersion: v1
kind: Namespace
metadata:
  name: neuvector       # Second namespace (pour un futur usage securite)
```

**Champs importants :**
- `apiVersion: v1` : les Namespaces font partie de l'API core, donc version `v1` (pas de groupe).
- `kind: Namespace` : le type de la ressource declaree.
- `metadata.name` : identifiant unique du namespace dans le cluster. Doit etre conforme au DNS (minuscules, tirets autorises, pas d'underscores).

### `nginx.yml` -- Definition du Pod

```yaml
apiVersion: v1
kind: Pod               # On cree un Pod directement (pas un Deployment)
metadata:
  name: nginx           # Nom du pod (unique dans le namespace)
  labels:
    app: nginx          # Label utilise par le Service pour router le trafic
  namespace: nginx      # Deploye dans le namespace nginx
spec:
  containers:
  - name: nginx         # Nom du conteneur dans le pod
    image: nginx:latest # Image Docker Hub officielle
    ports:
    - containerPort: 80 # Port expose par le conteneur (informatif)
    resources:
      limits:           # Maximum autorise
        memory: "256Mi" # 256 mebioctets de RAM max
        cpu: "500m"     # 500 millicores = 0.5 CPU max
      requests:         # Minimum garanti (utilise pour le scheduling)
        memory: "128Mi" # 128 mebioctets reserves
        cpu: "250m"     # 250 millicores = 0.25 CPU reserves
```

**Champs importants :**
- `kind: Pod` : dans ce TP, on cree un Pod directement. En production, on utiliserait un Deployment pour gerer le cycle de vie (replicas, rolling update). Le Pod seul n'a pas de mecanisme de restart automatique par un controller.
- `metadata.labels` : les labels sont des metadonnees arbitraires. Ici, `app: nginx` est la cle que le Service utilisera pour trouver ce Pod.
- `containerPort: 80` : ce champ est **informatif** (il ne bloque pas d'autres ports). Il documente que le conteneur ecoute sur le port 80.
- `resources.requests` : le scheduler ne placera ce Pod que sur un noeud disposant d'au moins 250m CPU et 128Mi memoire libres.
- `resources.limits` : si le conteneur depasse 256Mi de RAM, Kubernetes le tue avec un signal OOMKill. S'il depasse 500m CPU, il est ralenti (CPU throttling) mais pas tue.

### `service.yml` -- Exposition du Pod

```yaml
apiVersion: v1
kind: Service
metadata:
  name: nginx-service   # Nom du service (utilisable comme DNS interne)
  namespace: nginx
spec:
  type: LoadBalancer    # Type d'exposition
  selector:
    app: nginx          # Cible les Pods ayant le label app=nginx
  ports:
    - port: 80          # Port du service (cote client)
      targetPort: 80    # Port du conteneur cible
      protocol: TCP
```

**Champs importants :**
- `type: LoadBalancer` : demande un load balancer externe au cloud provider (ou a MetalLB/minikube tunnel). Sur minikube, utiliser `minikube tunnel` pour obtenir une IP externe. Sur Docker Desktop, le LoadBalancer est accessible sur `localhost`.
- `selector.app: nginx` : c'est le lien entre le Service et le Pod. Le Service ne route le trafic qu'aux Pods dont les labels matchent ce selector.
- `port: 80` : le port sur lequel le service ecoute. Les autres Pods du cluster peuvent acceder a ce service via `nginx-service.nginx.svc.cluster.local:80`.
- `targetPort: 80` : le port du conteneur vers lequel le trafic est redirige. Peut etre different de `port` (ex: service sur 80, conteneur sur 8080).

### `configMap.yml` -- Configuration PostgreSQL (optionnel)

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  namespace: nginx
  name: credentials
  labels:
    app: postgresdb
data:
  POSTGRES_DB: "myDatabase"
  POSTGRES_USER: "myUser"
  POSTGRES_PASSWORD: "myPassword"   # ATTENTION : en clair !
```

**Champs importants :**
- `kind: ConfigMap` : stocke des donnees de configuration sous forme de paires cle/valeur. Injectees comme variables d'environnement ou montees comme fichiers.
- `data` : chaque cle devient une variable d'environnement dans le conteneur qui reference ce ConfigMap via `envFrom`.
- **Attention** : les mots de passe en clair dans un ConfigMap sont visibles par toute personne ayant acces au namespace. Utiliser un Secret pour les donnees sensibles (voir TP02).

### `secrets.yml` -- Secrets encodes en Base64 (optionnel)

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: db-credentials
  namespace: nginx
  labels:
    app: postgresdb
type: Opaque            # Type generique (vs kubernetes.io/tls, etc.)
data:
  POSTGRES_USER: dGVzdHVzZXI=       # "testuser" en base64
  POSTGRES_PASSWORD: czNjcjN0        # "s3cr3t" en base64
```

**Champs importants :**
- `type: Opaque` : type generique pour des secrets arbitraires. D'autres types existent : `kubernetes.io/tls` pour les certificats, `kubernetes.io/dockerconfigjson` pour les credentials de registre.
- `data` : les valeurs doivent etre encodees en Base64. **Attention : Base64 n'est PAS du chiffrement**, c'est un simple encodage reversible. Pour decoder : `echo "dGVzdHVzZXI=" | base64 -d`.
- On peut utiliser `stringData` au lieu de `data` pour fournir les valeurs en clair (Kubernetes les encode automatiquement).

### `pv.yml` -- PersistentVolume (optionnel)

```yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  name: pv
  labels:
    type: local
    app: postgresdb
spec:
  storageClassName: standard    # Doit matcher le PVC
  capacity:
    storage: 8Gi               # 8 gibioctets de stockage
  accessModes:
    - ReadWriteMany             # Accessible en lecture/ecriture par plusieurs noeuds
  hostPath:
    path: "/data/db"            # Chemin sur le noeud hote
```

**Champs importants :**
- `storageClassName` : relie le PV au PVC. Le PVC demande une classe de stockage, et Kubernetes lie le PVC au PV qui a la meme classe et suffisamment de capacite.
- `accessModes: ReadWriteMany` (RWX) : le volume peut etre monte en lecture/ecriture par plusieurs noeuds simultanement. Autres modes : `ReadWriteOnce` (RWO, un seul noeud), `ReadOnlyMany` (ROX).
- `hostPath` : stocke les donnees directement sur le systeme de fichiers du noeud. **Uniquement pour le developpement** -- les donnees sont perdues si le Pod est replanifie sur un autre noeud.

### `pvc.yml` -- PersistentVolumeClaim (optionnel)

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  namespace: nginx
  name: pvc
spec:
  storageClassName: standard
  accessModes:
    - ReadWriteMany
  resources:
    requests:
      storage: 8Gi             # Demande 8Gi de stockage
```

**Champs importants :**
- Le PVC est une **demande de stockage** faite par l'utilisateur. Kubernetes cherche un PV compatible (meme storageClass, capacite suffisante, access mode compatible) et les lie ensemble.
- L'etat attendu apres application est `Bound` (lie).

### `postgres.yml` -- Deployment PostgreSQL (optionnel)

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  namespace: nginx
  name: postgresdb
spec:
  replicas: 1
  selector:
    matchLabels:
      app: postgresdb
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
                name: credentials    # Injecte toutes les cles du ConfigMap
          volumeMounts:
            - mountPath: /var/lib/postgresql  # Repertoire des donnees PostgreSQL
              name: db-data
      volumes:
        - name: db-data
          persistentVolumeClaim:
            claimName: pvc
```

**Champs importants :**
- `kind: Deployment` : contrairement au Pod nu utilise pour Nginx, un Deployment gere un ReplicaSet qui assure que le nombre de replicas souhaite est toujours respecte.
- `envFrom.configMapRef` : injecte **toutes** les cles du ConfigMap `credentials` comme variables d'environnement. Plus simple que de les declarer une par une avec `env`.
- `mountPath: /var/lib/postgresql` : repertoire ou PostgreSQL stocke ses donnees. Pour PostgreSQL 18+, utiliser `/var/lib/postgresql` et non `/var/lib/postgresql/data` (voir TP02 pour les details).

## Deploiement pas a pas

### 1. Creer les namespaces
```bash
kubectl apply -f namespaces.yml
```

### 2. Deployer le pod Nginx
```bash
kubectl apply -f nginx.yml
```

### 3. Verifier le pod
```bash
kubectl get pods -n nginx
kubectl describe pod nginx -n nginx
```

### 4. Tester l'acces via port-forward (sans service)
```bash
kubectl port-forward pod/nginx 8080:80 -n nginx
# Ouvrir http://localhost:8080 dans un navigateur
```

### 5. Exposer via un Service
```bash
kubectl apply -f service.yml
kubectl get svc -n nginx
```

### 6. (Optionnel) Deployer la stack PostgreSQL
```bash
kubectl apply -f configMap.yml
kubectl apply -f secrets.yml
kubectl apply -f pv.yml
kubectl apply -f pvc.yml
kubectl apply -f postgres.yml
```

## Commandes utiles

```bash
# Voir les ressources du namespace
kubectl get all -n nginx

# Labels et selectors
kubectl get pods -l app=nginx -n nginx

# Ajouter un label
kubectl label pod nginx env=dev -n nginx

# Supprimer un label
kubectl label pod nginx env- -n nginx

# Ressources consommees (necessite Metrics Server)
kubectl top pods -n nginx

# Voir les details du service
kubectl describe svc nginx-service -n nginx

# Verifier les endpoints du service (quels Pods sont cibles)
kubectl get endpoints nginx-service -n nginx
```

## Troubleshooting

### Le Pod reste en `Pending`
**Cause probable** : le namespace n'existe pas ou les ressources demandees depassent la capacite du noeud.
```bash
kubectl describe pod nginx -n nginx
# Chercher dans la section Events :
# "Insufficient cpu" ou "Insufficient memory"
```
**Solution** : reduire les `requests` ou ajouter un noeud au cluster.

### Le Pod est en `CrashLoopBackOff`
**Cause probable** : l'image est incorrecte ou le conteneur plante au demarrage.
```bash
kubectl logs nginx -n nginx
kubectl describe pod nginx -n nginx
```

### Le Service n'a pas d'`EXTERNAL-IP` (reste en `<pending>`)
**Cause probable** : pas de load balancer disponible.
```bash
# Sur minikube, lancer le tunnel :
minikube tunnel

# Sur Docker Desktop, le LoadBalancer est accessible sur localhost
```

### `port-forward` ne fonctionne pas
**Cause probable** : le pod n'est pas en etat `Running`.
```bash
kubectl get pods -n nginx -o wide
```

### Les labels du Pod ne matchent pas le selector du Service
```bash
# Verifier les labels du pod
kubectl get pod nginx -n nginx --show-labels

# Verifier le selector du service
kubectl describe svc nginx-service -n nginx | grep Selector

# Verifier les endpoints (doit lister le pod)
kubectl get endpoints nginx-service -n nginx
```

## Nettoyage

```bash
kubectl delete -f service.yml
kubectl delete -f nginx.yml
kubectl delete namespace nginx
```

## Pour aller plus loin

- [Documentation officielle Kubernetes : Pods](https://kubernetes.io/docs/concepts/workloads/pods/)
- [Documentation officielle Kubernetes : Services](https://kubernetes.io/docs/concepts/services-networking/service/)
- [Documentation officielle Kubernetes : Namespaces](https://kubernetes.io/docs/concepts/overview/working-with-objects/namespaces/)
- [Documentation officielle Kubernetes : Labels et Selectors](https://kubernetes.io/docs/concepts/overview/working-with-objects/labels/)
- [Documentation officielle Kubernetes : Resource Management](https://kubernetes.io/docs/concepts/configuration/manage-resources-containers/)

**Suggestions d'amelioration :**
- Remplacer le Pod nu par un Deployment avec `replicas: 2` pour la haute disponibilite
- Ajouter une `readinessProbe` et une `livenessProbe` au Pod Nginx
- Utiliser un tag d'image fixe (ex: `nginx:1.27`) au lieu de `latest` pour la reproductibilite
- Configurer une page d'accueil personnalisee via un ConfigMap monte dans `/usr/share/nginx/html`

## QCM de revision

**Question 1** : Quelle est la difference entre `requests` et `limits` dans la spec d'un conteneur ?

- A) `requests` est le maximum et `limits` est le minimum
- B) `requests` est la quantite garantie et `limits` est le maximum autorise
- C) `requests` et `limits` sont interchangeables
- D) `requests` sert au monitoring et `limits` au scheduling

<details>
<summary>Reponse</summary>
<b>B)</b> <code>requests</code> est la quantite de ressources garantie au conteneur (utilisee par le scheduler pour le placement).
<code>limits</code> est la quantite maximale que le conteneur peut consommer. Au-dela de la limit memoire, le conteneur est OOMKilled.
</details>

---

**Question 2** : Quel mecanisme permet a un Service de trouver les Pods auxquels il doit envoyer le trafic ?

- A) Le nom du Pod doit correspondre au nom du Service
- B) Le Service utilise un `selector` qui filtre les Pods par leurs labels
- C) Le Pod doit declarer explicitement le Service dans sa spec
- D) Le Service cible tous les Pods du meme namespace

<details>
<summary>Reponse</summary>
<b>B)</b> Le Service utilise un <code>selector</code> (ex: <code>app: nginx</code>) pour identifier dynamiquement les Pods cibles. Tout Pod ayant les labels correspondants recevra du trafic de ce Service.
</details>

---

**Question 3** : Que se passe-t-il si un Service de type LoadBalancer est cree sur un cluster minikube sans `minikube tunnel` ?

- A) Le Service fonctionne normalement
- B) Le Service est cree mais l'`EXTERNAL-IP` reste en `<pending>` indefiniment
- C) La creation du Service echoue avec une erreur
- D) Le Service est automatiquement converti en ClusterIP

<details>
<summary>Reponse</summary>
<b>B)</b> Le Service est cree avec succes mais aucune IP externe n'est attribuee. L'<code>EXTERNAL-IP</code> reste en <code>&lt;pending&gt;</code> car minikube n'a pas de cloud provider pour provisionner un load balancer. Il faut lancer <code>minikube tunnel</code> dans un terminal separe.
</details>

---

**Question 4** : Pourquoi est-il deconseille d'utiliser un Pod nu (sans Deployment) en production ?

- A) Les Pods nus ne supportent pas les labels
- B) Les Pods nus n'ont pas de controller pour les recreer en cas de panne
- C) Les Pods nus ne peuvent pas utiliser de volumes
- D) Les Pods nus ne sont pas compatibles avec les Services

<details>
<summary>Reponse</summary>
<b>B)</b> Un Pod nu n'est gere par aucun controller (ReplicaSet, Deployment). S'il est supprime ou si le noeud tombe en panne, personne ne le recree. Un Deployment garantit que le nombre de replicas souhaite est toujours maintenu.
</details>
