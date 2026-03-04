# TP06 - Gestion des ressources, autoscaling et scheduling

## Introduction theorique

Ce TP couvre les mecanismes avances de **gestion des ressources** dans Kubernetes. En production, il ne suffit pas de deployer des Pods : il faut controler combien de CPU et de memoire chaque namespace, chaque conteneur peut consommer, et comment les Pods sont places sur les noeuds du cluster. Nous allons manipuler cinq concepts complementaires : **ResourceQuota**, **LimitRange**, **HPA**, **Taints/Tolerations** et **Node Affinity**.

### ResourceQuota : le budget du namespace

Une ResourceQuota definit un **plafond global** de ressources pour un namespace entier. Elle limite le total de CPU, memoire, nombre de Pods, PVC, Services, etc. que tous les objets du namespace peuvent consommer ensemble.

```
Namespace: resource-mgmt
+-----------------------------------------------------------+
|  ResourceQuota: quota-postgres                            |
|  +--------------------------+---------------------------+ |
|  |  Requests                |  Limits                   | |
|  |  CPU total : 4 cores     |  CPU total : 8 cores      | |
|  |  Memoire   : 4Gi         |  Memoire   : 8Gi          | |
|  +--------------------------+---------------------------+ |
|  |  Pods max : 20    |  PVC max : 5   |  Svc max : 10  | |
|  +------------------+----------------+-----------------+ |
|                                                           |
|  Pod A (req: 250m CPU)  +  Pod B (req: 500m CPU)  = 750m |
|  --> Reste disponible : 4000m - 750m = 3250m CPU          |
+-----------------------------------------------------------+
```

**Point important** : des que vous activez une ResourceQuota sur un namespace, **tous les Pods** de ce namespace doivent obligatoirement declarer des `resources.requests` et `resources.limits`. Sinon, la creation du Pod est refusee par l'API Server. C'est pour cela qu'on combine souvent une ResourceQuota avec une LimitRange (qui fournit des valeurs par defaut).

### LimitRange : les garde-fous par conteneur

Tandis que la ResourceQuota controle le total du namespace, la LimitRange controle les ressources **de chaque conteneur individuellement**. Elle definit :

- **default** : les limits appliquees si le conteneur n'en declare pas
- **defaultRequest** : les requests appliquees si le conteneur n'en declare pas
- **min** : la quantite minimale autorisee (un conteneur demandant moins sera refuse)
- **max** : la quantite maximale autorisee (un conteneur demandant plus sera refuse)

```
LimitRange: limits-postgres
+-------------------------------------------------------+
|  min         defaultRequest    default         max     |
|  CPU  50m       100m            500m           2000m   |
|  Mem  64Mi      128Mi           256Mi          2Gi     |
|                                                       |
|  |--[=====]------[=========]-------|--------->        |
|  50m  100m       500m             2000m   CPU         |
|  ^     ^          ^                ^                  |
|  min  request   limit             max                 |
+-------------------------------------------------------+
```

Si un developpeur cree un Pod sans declarer de resources, Kubernetes lui attribue automatiquement `requests: 100m CPU / 128Mi` et `limits: 500m CPU / 256Mi` grace a la LimitRange.

### HPA : Horizontal Pod Autoscaler

Le HPA ajuste automatiquement le nombre de replicas d'un Deployment en fonction de metriques observees (CPU, memoire, ou metriques custom). Il interroge le **Metrics Server** a intervalles reguliers (par defaut 15 secondes) et calcule le ratio :

```
replicas souhaites = ceil( replicas actuels * (metrique actuelle / metrique cible) )
```

```
                   Metrics Server
                        |
                        v
                +---------------+
                |      HPA      |
                | min: 2        |
                | max: 10       |
                | cible CPU: 70%|
                +-------+-------+
                        |
         +--------------+--------------+
         v              v              v
   +-----------+  +-----------+  +-----------+
   | Pod #1    |  | Pod #2    |  | Pod #3    |
   | CPU: 85%  |  | CPU: 75%  |  | (cree)    |
   +-----------+  +-----------+  +-----------+
```

Le HPA ne descend jamais en dessous de `minReplicas` et ne monte jamais au-dessus de `maxReplicas`. Il gere aussi un **cooldown** pour eviter le "flapping" (scale up/down trop rapide).

### Taints et Tolerations

Les **Taints** sont des marqueurs places sur les **noeuds** pour repousser les Pods. Un Pod ne peut etre schedule sur un noeud taint que s'il possede une **Toleration** correspondante. C'est un mecanisme de **repulsion**.

```
Noeud A (taint: gpu=true:NoSchedule)
+------------------------------------------+
|  Seuls les Pods avec toleration          |
|  gpu=true:NoSchedule sont acceptes       |
|                                          |
|  [Pod gpu-job]  <-- toleration OK        |
|  [Pod nginx]    <-- REFUSE (pas de       |
|                     toleration)          |
+------------------------------------------+
```

Les trois effets possibles d'une Taint :
- **NoSchedule** : les nouveaux Pods sans toleration ne sont pas schedules sur ce noeud (les Pods existants restent)
- **PreferNoSchedule** : le scheduler evite ce noeud mais peut l'utiliser si aucun autre n'est disponible
- **NoExecute** : les Pods existants sans toleration sont **expulses** du noeud

### Node Affinity : l'attraction vers des noeuds

A l'inverse des Taints (repulsion), la **Node Affinity** est un mecanisme d'**attraction** : le Pod exprime une preference ou une exigence pour certains noeuds, en se basant sur leurs labels.

```
                         Noeuds du cluster
   +---------------+  +---------------+  +---------------+
   | Noeud 1       |  | Noeud 2       |  | Noeud 3       |
   | arch: amd64   |  | arch: amd64   |  | arch: arm64   |
   | type: ssd     |  | type: hdd     |  | type: ssd     |
   +-------+-------+  +-------+-------+  +-------+-------+
           ^                   ^
           |                   |
    PREFERE (ssd)     ACCEPTE (amd64)     REFUSE (arm64)
           |                   |
           +-------+-----------+
                   |
            [Pod app-with-affinity]
            required: arch=amd64
            preferred: type=ssd
```

Deux types de regles :
- **requiredDuringSchedulingIgnoredDuringExecution** (hard) : le Pod n'est **jamais** schedule sur un noeud qui ne matche pas
- **preferredDuringSchedulingIgnoredDuringExecution** (soft) : le scheduler **prefere** ces noeuds mais peut en choisir d'autres

## Objectifs

- Definir des quotas de ressources par namespace (ResourceQuota)
- Configurer des limites par defaut par conteneur (LimitRange)
- Mettre en place l'autoscaling horizontal (HPA)
- Controler le placement des pods avec Taints/Tolerations et Node Affinity

## Prerequis

- Un cluster Kubernetes fonctionnel (minikube, Docker Desktop, etc.)
- `kubectl` installe et configure
- Namespace `resource-mgmt` cree
- Metrics Server installe pour le HPA (`kubectl top nodes` doit fonctionner)

```bash
# Verifier que le Metrics Server fonctionne
kubectl top nodes

# Sur minikube, l'activer si necessaire
minikube addons enable metrics-server
```

## Architecture deployee

```
Cluster Kubernetes
+---------------------------------------------------------------------+
|                                                                     |
|  Namespace: resource-mgmt                                           |
|  +---------------------------------------------------------------+  |
|  |                                                               |  |
|  |  ResourceQuota (quota-postgres)                               |  |
|  |  CPU req: 4 | CPU lim: 8 | Mem req: 4Gi | Mem lim: 8Gi       |  |
|  |  Pods: 20 | PVC: 5 | Services: 10                            |  |
|  |                                                               |  |
|  |  LimitRange (limits-postgres)                                 |  |
|  |  default: 500m/256Mi | defaultReq: 100m/128Mi                 |  |
|  |  min: 50m/64Mi       | max: 2/2Gi                            |  |
|  |                                                               |  |
|  |  +--------------------+    HPA (postgresdb-hpa)               |  |
|  |  | Deployment         |    min: 2 | max: 10                   |  |
|  |  | postgresdb         |<---CPU cible: 70%                     |  |
|  |  | replicas: 2-10     |    Mem cible: 80%                     |  |
|  |  +--------------------+                                       |  |
|  +---------------------------------------------------------------+  |
|                                                                     |
|  Noeud avec taint gpu=true:NoSchedule                               |
|  +---------------------------------------------------------------+  |
|  |  [Pod gpu-job] (avec toleration)                              |  |
|  +---------------------------------------------------------------+  |
|                                                                     |
|  Noeud avec labels arch=amd64, type=ssd                             |
|  +---------------------------------------------------------------+  |
|  |  [Pod app-with-affinity] (avec nodeAffinity)                  |  |
|  +---------------------------------------------------------------+  |
|                                                                     |
+---------------------------------------------------------------------+
```

## Fichiers et explication detaillee

### `resourcequota.yaml` -- Quotas du namespace

```yaml
apiVersion: v1
kind: ResourceQuota
metadata:
  name: quota-postgres
  namespace: resource-mgmt       # Namespace cible
spec:
  hard:
    requests.cpu: "4"            # Total des requests CPU de tous les Pods
    requests.memory: 4Gi         # Total des requests memoire
    limits.cpu: "8"              # Total des limits CPU
    limits.memory: 8Gi           # Total des limits memoire
    pods: "20"                   # Nombre maximum de Pods
    persistentvolumeclaims: "5"  # Nombre maximum de PVC
    services: "10"               # Nombre maximum de Services
```

**Champs importants :**
- `spec.hard` : definit les quotas **durs** (hard limits). Toute creation de ressource qui ferait depasser un quota est refusee par l'Admission Controller.
- `requests.cpu: "4"` : signifie 4 cores au total. Si un Pod demande 250m (0.25 core) en request, on peut en creer jusqu'a 16 avant d'atteindre le quota (4 / 0.25 = 16, mais limite a 20 Pods max).
- `pods: "20"` : limite le nombre total de Pods dans le namespace, independamment de leurs ressources.
- `persistentvolumeclaims: "5"` : empeche la creation de plus de 5 PVC, utile pour controler la consommation de stockage.

### `limitrange.yaml` -- Limites par conteneur

```yaml
apiVersion: v1
kind: LimitRange
metadata:
  name: limits-postgres
  namespace: resource-mgmt
spec:
  limits:
    - type: Container            # S'applique a chaque conteneur
      default:                   # Limits par defaut (si non declarees)
        cpu: 500m
        memory: 256Mi
      defaultRequest:            # Requests par defaut (si non declarees)
        cpu: 100m
        memory: 128Mi
      max:                       # Maximum autorise par conteneur
        cpu: "2"
        memory: 2Gi
      min:                       # Minimum autorise par conteneur
        cpu: 50m
        memory: 64Mi
```

**Champs importants :**
- `type: Container` : la LimitRange peut aussi cibler `Pod` (total du Pod) ou `PersistentVolumeClaim` (taille du PVC).
- `default` vs `defaultRequest` : `default` definit les **limits** par defaut, `defaultRequest` definit les **requests** par defaut. Si seul `default` est specifie, les requests prennent la meme valeur que les limits.
- `min` et `max` : tout conteneur dont les requests/limits sont en dehors de cette plage sera refuse. Cela empeche un developpeur de demander 100 CPU ou 0 CPU.
- L'interaction avec ResourceQuota est essentielle : la LimitRange assure que chaque Pod a des requests/limits, ce qui permet a la ResourceQuota de fonctionner (elle a besoin de ces valeurs pour comptabiliser la consommation).

### `hpa.yaml` -- Horizontal Pod Autoscaler

```yaml
apiVersion: autoscaling/v2       # v2 supporte plusieurs metriques
kind: HorizontalPodAutoscaler
metadata:
  name: postgresdb-hpa
  namespace: resource-mgmt
spec:
  scaleTargetRef:                # Deployment cible
    apiVersion: apps/v1
    kind: Deployment
    name: postgresdb
  minReplicas: 2                 # Jamais moins de 2 replicas
  maxReplicas: 10                # Jamais plus de 10 replicas
  metrics:
    - type: Resource             # Metrique de type ressource (CPU/memoire)
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 70  # Scale si CPU moyen > 70%
    - type: Resource
      resource:
        name: memory
        target:
          type: Utilization
          averageUtilization: 80  # Scale si memoire moyenne > 80%
```

**Champs importants :**
- `apiVersion: autoscaling/v2` : la v2 permet de definir **plusieurs metriques** simultanement (CPU + memoire). L'ancienne v1 ne supportait que le CPU.
- `scaleTargetRef` : reference au Deployment cible. Le HPA modifie le champ `spec.replicas` du Deployment.
- `averageUtilization: 70` : c'est le pourcentage **moyen** sur tous les Pods. Si 2 Pods ont respectivement 60% et 80% de CPU, la moyenne est 70% et le HPA ne scale pas.
- Avec plusieurs metriques, le HPA calcule le nombre de replicas pour **chacune** et prend le **maximum**. Si le CPU demande 3 replicas et la memoire 5, le HPA met 5.
- `minReplicas: 2` : garantit une haute disponibilite meme en periode creuse.

### `taints-tolerations.yaml` -- Pod avec Toleration

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: gpu-job
  namespace: default
spec:
  tolerations:                   # Le Pod "tolere" la taint du noeud
    - key: "gpu"                 # Cle de la taint
      operator: "Equal"          # Correspondance exacte (cle + valeur)
      value: "true"              # Valeur attendue
      effect: "NoSchedule"      # Effet de la taint toleree
  containers:
    - name: gpu-job
      image: tensorflow/tensorflow:latest-gpu
```

**Champs importants :**
- `operator: "Equal"` : la cle ET la valeur doivent correspondre. L'alternative est `"Exists"` qui ne verifie que la cle (utile pour tolerer toutes les valeurs d'une cle).
- `effect: "NoSchedule"` : cette Toleration ne concerne que les Taints avec l'effet `NoSchedule`. Pour tolerer tous les effets, omettre le champ `effect`.
- Un Pod avec une Toleration n'est **pas force** d'aller sur le noeud taint : il est simplement **autorise** a y aller. Pour forcer le placement, combiner avec une Node Affinity.

### `node-affinity.yaml` -- Pod avec Node Affinity

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: app-with-affinity
  namespace: default
spec:
  affinity:
    nodeAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:    # HARD
        nodeSelectorTerms:
          - matchExpressions:
              - key: kubernetes.io/arch    # Label standard Kubernetes
                operator: In
                values: ["amd64"]          # Le noeud DOIT etre amd64
      preferredDuringSchedulingIgnoredDuringExecution:   # SOFT
        - weight: 1                        # Poids de la preference (1-100)
          preference:
            matchExpressions:
              - key: node-type
                operator: In
                values: ["ssd"]            # Prefere les noeuds SSD
  containers:
    - name: mon-app
      image: nginx:latest
```

**Champs importants :**
- `requiredDuringSchedulingIgnoredDuringExecution` : regle **obligatoire**. Si aucun noeud ne correspond, le Pod reste en `Pending`. Le suffixe `IgnoredDuringExecution` signifie que si le label du noeud change apres le scheduling, le Pod n'est **pas** expulse.
- `preferredDuringSchedulingIgnoredDuringExecution` : regle **preferentielle**. Le scheduler attribue un score supplementaire aux noeuds qui matchent.
- `weight: 1` : poids de la preference (de 1 a 100). Si plusieurs regles preferred existent, les poids s'additionnent pour classer les noeuds.
- `operator: In` : le label doit etre dans la liste de valeurs. Autres operateurs : `NotIn`, `Exists`, `DoesNotExist`, `Gt`, `Lt`.
- `kubernetes.io/arch` : label standard ajoute automatiquement par Kubernetes sur chaque noeud. Autres labels courants : `kubernetes.io/os`, `topology.kubernetes.io/zone`.

## Deploiement pas a pas

### 1. Creer le namespace

```bash
kubectl create namespace resource-mgmt
```

Sortie attendue :
```
namespace/resource-mgmt created
```

### 2. Appliquer la ResourceQuota

```bash
kubectl apply -f resourcequota.yaml
```

Verifier les quotas :
```bash
kubectl describe quota quota-postgres -n resource-mgmt
```

Sortie attendue :
```
Name:                   quota-postgres
Namespace:              resource-mgmt
Resource                Used  Hard
--------                ----  ----
limits.cpu              0     8
limits.memory           0     8Gi
persistentvolumeclaims  0     5
pods                    0     20
requests.cpu            0     4
requests.memory         0     4Gi
services                0     10
```

### 3. Appliquer la LimitRange

```bash
kubectl apply -f limitrange.yaml
```

Verifier les limites :
```bash
kubectl describe limitrange limits-postgres -n resource-mgmt
```

Sortie attendue :
```
Type        Resource  Min   Max  Default  Default Request
----        --------  ---   ---  -------  ---------------
Container   cpu       50m   2    500m     100m
Container   memory    64Mi  2Gi  256Mi    128Mi
```

### 4. Tester l'interaction Quota + LimitRange

Creons un Pod sans resources pour verifier que la LimitRange injecte les valeurs par defaut :

```bash
kubectl run test-pod --image=nginx -n resource-mgmt
kubectl describe pod test-pod -n resource-mgmt | grep -A 4 "Limits\|Requests"
```

Sortie attendue :
```
    Limits:
      cpu:     500m
      memory:  256Mi
    Requests:
      cpu:     100m
      memory:  128Mi
```

Verifier que la ResourceQuota a ete mise a jour :
```bash
kubectl describe quota quota-postgres -n resource-mgmt
```

```
Resource         Used   Hard
--------         ----   ----
requests.cpu     100m   4
requests.memory  128Mi  4Gi
limits.cpu       500m   8
limits.memory    256Mi  8Gi
pods             1      20
```

Nettoyer le Pod de test :
```bash
kubectl delete pod test-pod -n resource-mgmt
```

### 5. Deployer le HPA

```bash
kubectl apply -f hpa.yaml
```

Verifier l'etat du HPA :
```bash
kubectl get hpa -n resource-mgmt
```

Sortie attendue :
```
NAME             REFERENCE              TARGETS                        MINPODS   MAXPODS   REPLICAS   AGE
postgresdb-hpa   Deployment/postgresdb   cpu: <unknown>/70%, memory: <unknown>/80%   2        10        0         10s
```

> **Note** : `<unknown>` est normal si le Deployment `postgresdb` n'existe pas encore ou si le Metrics Server n'a pas encore collecte de donnees. Apres quelques minutes, les valeurs reelles apparaitront.

La forme imperative equivalente serait :
```bash
kubectl autoscale deployment postgresdb \
  --cpu-percent=70 --min=2 --max=10 -n resource-mgmt
```

### 6. Taints et Tolerations

```bash
# Lister les noeuds
kubectl get nodes

# Ajouter une taint sur un noeud (remplacer <node-name> par le nom reel)
kubectl taint nodes <node-name> gpu=true:NoSchedule

# Verifier la taint
kubectl describe node <node-name> | grep -A 2 Taints

# Deployer le Pod avec la Toleration
kubectl apply -f taints-tolerations.yaml

# Verifier que le Pod est schedule
kubectl get pod gpu-job -o wide

# Retirer la taint apres le test
kubectl taint nodes <node-name> gpu=true:NoSchedule-
```

### 7. Node Affinity

```bash
# Verifier les labels existants sur les noeuds
kubectl get nodes --show-labels

# Dry-run pour valider le manifest
kubectl apply --dry-run=server -f node-affinity.yaml

# Appliquer (le Pod sera schedule si un noeud amd64 existe)
kubectl apply -f node-affinity.yaml

# Verifier sur quel noeud le Pod a ete place
kubectl get pod app-with-affinity -o wide
```

## Commandes utiles

```bash
# Voir la consommation du namespace vs les quotas
kubectl describe quota -n resource-mgmt

# Voir les limites en vigueur
kubectl describe limitrange -n resource-mgmt

# Suivre l'etat du HPA en temps reel
kubectl get hpa -n resource-mgmt -w

# Voir les metriques de CPU/memoire des Pods
kubectl top pods -n resource-mgmt

# Voir les metriques des noeuds
kubectl top nodes

# Voir les taints d'un noeud
kubectl describe node <node-name> | grep Taints

# Voir les labels d'un noeud
kubectl get node <node-name> --show-labels

# Ajouter un label a un noeud
kubectl label node <node-name> node-type=ssd

# Retirer un label
kubectl label node <node-name> node-type-
```

## Troubleshooting

### Le Pod est refuse avec "forbidden: exceeded quota"

**Cause** : la creation du Pod ferait depasser un quota de la ResourceQuota.
```bash
kubectl describe quota -n resource-mgmt
# Verifier la colonne "Used" vs "Hard"
```
**Solution** : reduire les requests/limits du Pod, supprimer d'autres Pods pour liberer du quota, ou augmenter les quotas.

### Le Pod est refuse avec "must specify limits/requests"

**Cause** : une ResourceQuota est active mais il n'y a pas de LimitRange pour fournir des valeurs par defaut, et le Pod ne declare pas de resources.
```bash
kubectl get limitrange -n resource-mgmt
```
**Solution** : ajouter des `resources.requests` et `resources.limits` dans le Pod, ou appliquer une LimitRange.

### Le Pod est refuse avec "minimum cpu usage per Container is 50m"

**Cause** : le conteneur demande moins de CPU que le `min` de la LimitRange.
```bash
kubectl describe limitrange -n resource-mgmt
```
**Solution** : augmenter les requests/limits du conteneur pour respecter le minimum.

### Le HPA affiche `<unknown>` pour les metriques

**Cause** : le Metrics Server n'est pas installe ou n'a pas encore collecte de donnees.
```bash
# Verifier que le Metrics Server tourne
kubectl get pods -n kube-system | grep metrics-server

# Sur minikube
minikube addons enable metrics-server

# Attendre 1-2 minutes puis reverifier
kubectl top pods -n resource-mgmt
```

### Le HPA ne scale pas malgre une charge elevee

**Cause possible** : les Pods n'ont pas de `resources.requests` definies. Le HPA calcule le pourcentage par rapport aux requests, pas aux limits.
```bash
kubectl describe hpa postgresdb-hpa -n resource-mgmt
# Verifier les conditions et evenements
```

### Le Pod avec Toleration reste en Pending

**Cause** : avoir une Toleration ne **force pas** le Pod a aller sur le noeud taint. Si tous les autres noeuds sont aussi satures, le Pod reste en Pending.
```bash
kubectl describe pod gpu-job
# Chercher "FailedScheduling" dans les Events
```
**Solution** : verifier que le cluster a des noeuds avec suffisamment de ressources.

### Le Pod avec Node Affinity reste en Pending

**Cause** : aucun noeud ne satisfait la contrainte `required`.
```bash
kubectl get nodes --show-labels | grep arch
```
**Solution** : verifier que les labels requis existent sur au moins un noeud. Sur minikube :
```bash
kubectl label node minikube kubernetes.io/arch=amd64
```

## Recapitulatif

| Ressource | Scope | Effet |
|-----------|-------|-------|
| ResourceQuota | Namespace | Total de ressources consommables |
| LimitRange | Namespace | Limites par conteneur (defaut, min, max) |
| HPA | Deployment | Autoscaling base sur les metriques |
| Taint | Noeud | Repousse les Pods sans Toleration |
| Toleration | Pod | Permet d'ignorer une Taint |
| Node Affinity | Pod | Attire vers des noeuds specifiques |

## Nettoyage

```bash
kubectl delete -f hpa.yaml
kubectl delete -f limitrange.yaml
kubectl delete -f resourcequota.yaml
kubectl delete -f taints-tolerations.yaml
kubectl delete -f node-affinity.yaml
kubectl delete namespace resource-mgmt
```

## Pour aller plus loin

- [Documentation officielle : Resource Quotas](https://kubernetes.io/docs/concepts/policy/resource-quotas/)
- [Documentation officielle : Limit Ranges](https://kubernetes.io/docs/concepts/policy/limit-range/)
- [Documentation officielle : Horizontal Pod Autoscaling](https://kubernetes.io/docs/tasks/run-application/horizontal-pod-autoscale/)
- [Documentation officielle : Taints and Tolerations](https://kubernetes.io/docs/concepts/scheduling-eviction/taint-and-toleration/)
- [Documentation officielle : Assigning Pods to Nodes](https://kubernetes.io/docs/concepts/scheduling-eviction/assign-pod-node/)
- [Documentation officielle : Pod Priority and Preemption](https://kubernetes.io/docs/concepts/scheduling-eviction/pod-priority-preemption/)

**Suggestions d'amelioration :**
- Ajouter un **VPA** (Vertical Pod Autoscaler) pour ajuster automatiquement les requests/limits de chaque Pod
- Combiner Taints + Node Affinity pour un placement precis (repulsion + attraction)
- Utiliser des **PodDisruptionBudgets** (PDB) pour garantir un nombre minimum de Pods disponibles pendant les maintenances
- Explorer les **metriques custom** avec le HPA (ex: nombre de connexions PostgreSQL, taille de la queue)
- Tester le **Cluster Autoscaler** qui ajoute/retire des noeuds en fonction de la charge globale

## QCM de revision

**Question 1** : Que se passe-t-il si une ResourceQuota est active sur un namespace et qu'un Pod ne declare pas de `resources.requests` ?

- A) Le Pod est cree avec des valeurs par defaut de Kubernetes
- B) La creation du Pod est refusee par l'API Server
- C) Le Pod est cree mais ne consomme pas de ressources
- D) Le Pod est cree en mode "best effort" sans garantie

<details>
<summary>Reponse</summary>
<b>B)</b> Quand une ResourceQuota est active, l'Admission Controller exige que chaque Pod declare des <code>resources.requests</code> et <code>resources.limits</code>. Sans ces declarations, la creation est refusee. C'est pourquoi on combine souvent une ResourceQuota avec une LimitRange qui fournit des valeurs par defaut.
</details>

---

**Question 2** : Quelle est la difference entre `default` et `defaultRequest` dans une LimitRange ?

- A) `default` s'applique aux Pods et `defaultRequest` aux conteneurs
- B) `default` definit les limits par defaut et `defaultRequest` definit les requests par defaut
- C) Ce sont deux synonymes interchangeables
- D) `default` est pour le CPU et `defaultRequest` pour la memoire

<details>
<summary>Reponse</summary>
<b>B)</b> <code>default</code> definit les <b>limits</b> appliquees automatiquement si un conteneur ne les declare pas. <code>defaultRequest</code> definit les <b>requests</b> par defaut. Si seul <code>default</code> est defini, les requests prennent la meme valeur que les limits.
</details>

---

**Question 3** : Un HPA est configure avec `averageUtilization: 70` pour le CPU. 3 Pods ont respectivement 90%, 50% et 60% de CPU. Que fait le HPA ?

- A) Il scale car un Pod depasse 70%
- B) Il ne scale pas car la moyenne est 66.7%
- C) Il supprime le Pod a 90%
- D) Il reduit a 2 Pods

<details>
<summary>Reponse</summary>
<b>B)</b> Le HPA calcule la <b>moyenne</b> sur tous les Pods : (90 + 50 + 60) / 3 = 66.7%. Comme 66.7% < 70%, le seuil n'est pas atteint et le HPA ne scale pas. C'est un calcul global, pas par Pod.
</details>

---

**Question 4** : Quelle est la difference entre un Taint avec l'effet `NoSchedule` et un Taint avec l'effet `NoExecute` ?

- A) `NoSchedule` empeche le scheduling, `NoExecute` empeche l'execution de commandes
- B) `NoSchedule` bloque les nouveaux Pods, `NoExecute` expulse aussi les Pods existants
- C) `NoSchedule` est pour les Pods, `NoExecute` est pour les Deployments
- D) Il n'y a pas de difference fonctionnelle

<details>
<summary>Reponse</summary>
<b>B)</b> <code>NoSchedule</code> empeche les <b>nouveaux</b> Pods sans toleration d'etre schedules sur le noeud, mais les Pods deja en cours d'execution restent. <code>NoExecute</code> va plus loin : il <b>expulse</b> egalement les Pods existants qui n'ont pas la toleration correspondante.
</details>

---

**Question 5** : Un Pod a une Node Affinity `required` sur `arch=amd64` et une `preferred` sur `type=ssd`. Aucun noeud amd64 n'existe dans le cluster. Que se passe-t-il ?

- A) Le Pod est schedule sur un noeud SSD quel que soit l'architecture
- B) Le Pod est schedule sur n'importe quel noeud car la regle preferred s'applique
- C) Le Pod reste en Pending indefiniment
- D) Le Pod est rejete avec une erreur

<details>
<summary>Reponse</summary>
<b>C)</b> La regle <code>required</code> est <b>obligatoire</b>. Si aucun noeud ne satisfait la contrainte (arch=amd64), le Pod ne peut pas etre schedule et reste en <code>Pending</code>. La regle <code>preferred</code> n'intervient que pour departager les noeuds qui satisfont deja les regles required.
</details>

---

**Question 6** : Quelle est la difference entre une Node Affinity et un nodeSelector ?

- A) Ils sont identiques
- B) nodeSelector ne supporte que l'egalite exacte, Node Affinity supporte des operateurs avances (In, NotIn, Exists, Gt, Lt)
- C) nodeSelector est pour les noeuds, Node Affinity est pour les Pods
- D) nodeSelector est deprecie en faveur de Node Affinity

<details>
<summary>Reponse</summary>
<b>B)</b> <code>nodeSelector</code> ne supporte que l'egalite stricte (cle=valeur). <code>Node Affinity</code> offre des operateurs avances (<code>In</code>, <code>NotIn</code>, <code>Exists</code>, <code>DoesNotExist</code>, <code>Gt</code>, <code>Lt</code>), des regles preferentielles avec poids, et la possibilite de combiner plusieurs criteres. <code>nodeSelector</code> n'est pas deprecie mais Node Affinity est plus expressif.
</details>

---

**Question 7** : Dans quel ordre le scheduler Kubernetes evalue-t-il les contraintes de placement ?

- A) Taints, puis Node Affinity, puis ResourceQuota
- B) ResourceQuota, puis LimitRange, puis Taints
- C) Les Taints et Node Affinity sont evalues ensemble pendant le filtering, la ResourceQuota est verifiee par l'Admission Controller avant
- D) L'ordre n'a pas d'importance

<details>
<summary>Reponse</summary>
<b>C)</b> Le processus se deroule en deux phases. D'abord, l'<b>Admission Controller</b> verifie les quotas (ResourceQuota) et injecte les valeurs par defaut (LimitRange). Ensuite, le <b>scheduler</b> filtre les noeuds eligibles en evaluant les Taints/Tolerations et la Node Affinity, puis classe les noeuds restants par score (incluant les preferences).
</details>
