# TP04 - RBAC -- Controle d'acces base sur les roles

## Introduction theorique

Le RBAC (Role-Based Access Control) est le mecanisme d'autorisation principal de Kubernetes. Il permet de controler **qui** peut faire **quoi** sur **quelles ressources** dans le cluster. Sans RBAC, tout utilisateur ou Pod aurait un acces illimite a l'API Kubernetes, ce qui serait catastrophique en production.

### Pourquoi le RBAC est essentiel ?

Imaginez un cluster partage entre plusieurs equipes. Sans controle d'acces :
- Un developpeur pourrait accidentellement supprimer les Pods d'une autre equipe
- Une application compromise pourrait lire les Secrets de tout le cluster
- Un script mal ecrit pourrait modifier les Nodes du cluster

Le RBAC applique le **principe du moindre privilege** : chaque identite (utilisateur, groupe, ServiceAccount) ne recoit que les permissions strictement necessaires a son fonctionnement.

### Les 4 ressources RBAC

Le systeme RBAC de Kubernetes repose sur 4 types de ressources, organises en 2 axes :

```
                       Portee
                 Namespace      Cluster
              +--------------+--------------+
  Permissions |    Role      | ClusterRole  |
              +--------------+--------------+
  Liaison     | RoleBinding  | ClusterRole  |
              |              |   Binding    |
              +--------------+--------------+
```

1. **Role** : definit un ensemble de permissions (verbes + ressources) dans un namespace specifique.
2. **ClusterRole** : definit un ensemble de permissions au niveau du cluster entier (ou sur des ressources non-namespacees comme les Nodes).
3. **RoleBinding** : lie un Role (ou un ClusterRole) a une identite dans un namespace.
4. **ClusterRoleBinding** : lie un ClusterRole a une identite au niveau du cluster entier.

### Qu'est-ce qu'un ServiceAccount ?

Un ServiceAccount est une **identite pour les Pods**. Contrairement aux utilisateurs humains (geres en dehors de Kubernetes via des certificats ou un fournisseur d'identite), les ServiceAccounts sont des objets Kubernetes natifs.

Chaque namespace possede un ServiceAccount `default` cree automatiquement. Tout Pod qui ne specifie pas de ServiceAccount utilise ce compte par defaut. En production, on cree des ServiceAccounts dedies pour chaque application afin d'appliquer le moindre privilege.

```
+----------------------------------+
|  Identites dans Kubernetes       |
|                                  |
|  +----------------------------+  |
|  | Utilisateurs (humains)     |  |
|  | - Certificats X509         |  |
|  | - Tokens OIDC              |  |
|  | - Geres hors Kubernetes    |  |
|  +----------------------------+  |
|                                  |
|  +----------------------------+  |
|  | ServiceAccounts (Pods)     |  |
|  | - Objets Kubernetes natifs |  |
|  | - Un par namespace (defaut)|  |
|  | - Token monte dans le Pod  |  |
|  +----------------------------+  |
|                                  |
|  +----------------------------+  |
|  | Groupes                    |  |
|  | - system:masters           |  |
|  | - system:authenticated     |  |
|  +----------------------------+  |
+----------------------------------+
```

### Les verbes RBAC

Les verbes definissent les actions autorisees sur les ressources. Ils correspondent aux operations de l'API Kubernetes :

| Verbe | Operation HTTP | Description |
|-------|---------------|-------------|
| `get` | GET (unitaire) | Lire une ressource specifique par son nom |
| `list` | GET (collection) | Lister toutes les ressources d'un type |
| `watch` | GET (streaming) | Surveiller les changements en temps reel |
| `create` | POST | Creer une nouvelle ressource |
| `update` | PUT | Remplacer entierement une ressource |
| `patch` | PATCH | Modifier partiellement une ressource |
| `delete` | DELETE | Supprimer une ressource |
| `deletecollection` | DELETE (collection) | Supprimer toutes les ressources d'un type |

### Les apiGroups

Les ressources Kubernetes sont organisees en groupes d'API :

| apiGroup | Ressources |
|----------|------------|
| `""` (core, vide) | pods, services, secrets, configmaps, namespaces, nodes, persistentvolumes |
| `apps` | deployments, replicasets, statefulsets, daemonsets |
| `rbac.authorization.k8s.io` | roles, rolebindings, clusterroles, clusterrolebindings |
| `networking.k8s.io` | networkpolicies, ingresses |
| `batch` | jobs, cronjobs |

Pour decouvrir tous les groupes d'API et les ressources associees :
```bash
kubectl api-resources
```

## Objectifs

- Creer un ServiceAccount dedie pour une application
- Definir des permissions precises avec Role et ClusterRole
- Lier les permissions aux identites avec RoleBinding
- Verifier les permissions avec `kubectl auth can-i`
- Comprendre la difference entre Role (namespace-scoped) et ClusterRole (cluster-wide)

## Prerequis

- Un cluster Kubernetes fonctionnel (minikube, Docker Desktop, etc.)
- `kubectl` installe et configure
- Namespace `postgres` existant (TP02)

## Architecture deployee

```
Cluster Kubernetes
+-----------------------------------------------------------------------+
|                                                                       |
|  Namespace: postgres                                                  |
|  +-------------------------------------------------------------------+|
|  |                                                                   ||
|  |  ServiceAccount: mon-app                                          ||
|  |       |                                                           ||
|  |       |  (lie par)                                                ||
|  |       v                                                           ||
|  |  RoleBinding: read-pods                                           ||
|  |       |                                                           ||
|  |       |  (reference)                                              ||
|  |       v                                                           ||
|  |  Role: pod-reader                                                 ||
|  |    - pods: get, list, watch                                       ||
|  |    - pods/log: get, list, watch                                   ||
|  |                                                                   ||
|  +-------------------------------------------------------------------+|
|                                                                       |
|  Ressources cluster-wide (pas de namespace)                           |
|  +-------------------------------------------------------------------+|
|  |                                                                   ||
|  |  ClusterRole: node-reader                                         ||
|  |    - nodes: get, list, watch                                      ||
|  |                                                                   ||
|  |  (necessite un ClusterRoleBinding pour etre effectif)              ||
|  |                                                                   ||
|  +-------------------------------------------------------------------+|
|                                                                       |
+-----------------------------------------------------------------------+
```

### Flux d'autorisation RBAC

```
  Pod (avec ServiceAccount mon-app)
       |
       | requete API : "GET /api/v1/namespaces/postgres/pods"
       v
  API Server
       |
       | 1. Authentification : qui fait la requete ?
       |    --> ServiceAccount "mon-app" dans "postgres"
       |
       | 2. Autorisation (RBAC) : a-t-il le droit ?
       |    --> Cherche les RoleBindings dans "postgres"
       |    --> Trouve "read-pods" qui lie "mon-app" a "pod-reader"
       |    --> "pod-reader" autorise "get,list,watch" sur "pods"
       |    --> Verbe "get" sur "pods" --> AUTORISE
       |
       | 3. Admission : la requete est-elle valide ?
       |    --> OK
       v
  Reponse : liste des pods
```

## Fichiers et explication detaillee

### `serviceaccount.yaml` -- Creation de l'identite

```yaml
apiVersion: v1              # Les ServiceAccounts font partie de l'API core
kind: ServiceAccount
metadata:
  name: mon-app             # Nom du ServiceAccount
  namespace: postgres       # Cree dans le namespace postgres
```

**Champs importants :**
- `kind: ServiceAccount` : cree une identite pour les Pods. Un Pod peut referencer ce ServiceAccount via `spec.serviceAccountName: mon-app`.
- `namespace: postgres` : le ServiceAccount est namespace-scoped. Il n'existe que dans le namespace `postgres`.
- Kubernetes cree automatiquement un token JWT associe a ce ServiceAccount. Ce token est monte dans le Pod sous `/var/run/secrets/kubernetes.io/serviceaccount/token`.

**Bonne pratique :** Creer un ServiceAccount dedie par application plutot que d'utiliser le ServiceAccount `default`. Cela permet d'appliquer le moindre privilege et de tracer les actions par application.

### `role.yaml` -- Definition des permissions (namespace-scoped)

```yaml
apiVersion: rbac.authorization.k8s.io/v1   # API RBAC
kind: Role
metadata:
  name: pod-reader
  namespace: postgres                       # Portee limitee a ce namespace
rules:
  - apiGroups: [""]                         # Groupe core (pods, services, etc.)
    resources: ["pods", "pods/log"]         # Ressources ciblees
    verbs: ["get", "list", "watch"]         # Actions autorisees
```

**Champs importants :**
- `apiVersion: rbac.authorization.k8s.io/v1` : le RBAC a sa propre API group. Toutes les ressources RBAC utilisent cette version.
- `kind: Role` : un Role est **namespace-scoped**. Les permissions qu'il definit ne s'appliquent que dans le namespace `postgres`.
- `rules` : liste des regles d'autorisation. Chaque regle est un triplet (apiGroups, resources, verbs).
- `apiGroups: [""]` : la chaine vide designe le groupe core de l'API (`/api/v1`). Les pods et leurs sous-ressources en font partie.
- `resources: ["pods", "pods/log"]` : cible les pods et la sous-ressource `pods/log` (pour `kubectl logs`). Les sous-ressources sont separees par un `/`.
- `verbs: ["get", "list", "watch"]` : autorise uniquement la lecture. Le ServiceAccount ne pourra pas creer, modifier ou supprimer des pods.

**Remarque :** On peut combiner plusieurs regles dans un meme Role pour donner des permissions sur des ressources differentes :
```yaml
rules:
  - apiGroups: [""]
    resources: ["pods"]
    verbs: ["get", "list"]
  - apiGroups: [""]
    resources: ["services"]
    verbs: ["get", "list", "create"]
```

### `rolebinding.yaml` -- Liaison Role / ServiceAccount

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: read-pods
  namespace: postgres                    # Meme namespace que le Role
subjects:                                # QUI recoit les permissions
  - kind: ServiceAccount
    name: mon-app
    namespace: postgres
roleRef:                                 # QUEL Role est attribue
  kind: Role
  name: pod-reader
  apiGroup: rbac.authorization.k8s.io
```

**Champs importants :**
- `subjects` : la liste des identites qui recoivent les permissions. Peut contenir des ServiceAccounts, des Users ou des Groups.
- `subjects[].kind` : le type d'identite. Valeurs possibles : `ServiceAccount`, `User`, `Group`.
- `subjects[].namespace` : obligatoire pour les ServiceAccounts. Indique dans quel namespace le ServiceAccount existe.
- `roleRef` : reference au Role (ou ClusterRole) qui definit les permissions. **Attention : le roleRef est immuable.** Pour changer le Role reference, il faut supprimer et recreer le RoleBinding.
- `roleRef.kind` : peut etre `Role` ou `ClusterRole`. Un RoleBinding peut referencer un ClusterRole pour limiter ses permissions au namespace du RoleBinding.

### `clusterrole.yaml` -- Permissions cluster-wide

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: node-reader           # Pas de namespace : c'est cluster-wide
rules:
  - apiGroups: [""]
    resources: ["nodes"]       # Les nodes sont des ressources non-namespacees
    verbs: ["get", "list", "watch"]
```

**Champs importants :**
- `kind: ClusterRole` : les permissions s'appliquent au niveau du cluster entier. Pas de champ `namespace` dans les metadata.
- `resources: ["nodes"]` : les Nodes sont des ressources **non-namespacees**. Elles ne peuvent etre ciblees que par un ClusterRole, pas par un Role.
- Pour que ce ClusterRole soit effectif, il faut le lier a une identite via un **ClusterRoleBinding** (non fourni dans ce TP, a creer en exercice).

**Ressources non-namespacees courantes :** nodes, persistentvolumes, clusterroles, clusterrolebindings, namespaces, storageclasses.

## Deploiement pas a pas

### 1. Verifier le namespace

```bash
kubectl get namespace postgres
```

Sortie attendue :
```
NAME       STATUS   AGE
postgres   Active   2d
```

Si le namespace n'existe pas, creez-le :
```bash
kubectl create namespace postgres
```

### 2. Creer le ServiceAccount

```bash
kubectl apply -f serviceaccount.yaml
```

Verifier :
```bash
kubectl get serviceaccounts -n postgres
```

Sortie attendue :
```
NAME      SECRETS   AGE
default   0         2d
mon-app   0         5s
```

### 3. Creer le Role

```bash
kubectl apply -f role.yaml
```

Verifier :
```bash
kubectl get roles -n postgres
```

Sortie attendue :
```
NAME         CREATED AT
pod-reader   2025-01-15T10:30:00Z
```

Pour voir les details des permissions :
```bash
kubectl describe role pod-reader -n postgres
```

Sortie attendue :
```
Name:         pod-reader
Labels:       <none>
Annotations:  <none>
PolicyRule:
  Resources  Non-Resource URLs  Resource Names  Verbs
  ---------  -----------------  --------------  -----
  pods/log   []                 []              [get list watch]
  pods       []                 []              [get list watch]
```

### 4. Creer le RoleBinding

```bash
kubectl apply -f rolebinding.yaml
```

Verifier :
```bash
kubectl describe rolebinding read-pods -n postgres
```

Sortie attendue :
```
Name:         read-pods
Role:
  Kind:  Role
  Name:  pod-reader
Subjects:
  Kind            Name     Namespace
  ----            ----     ---------
  ServiceAccount  mon-app  postgres
```

### 5. Creer le ClusterRole

```bash
kubectl apply -f clusterrole.yaml
```

Verifier :
```bash
kubectl get clusterroles node-reader
```

### 6. Verifier les permissions avec `kubectl auth can-i`

La commande `kubectl auth can-i` permet de tester les permissions sans executer l'action reelle. L'option `--as` permet de simuler l'identite d'un ServiceAccount.

```bash
# Le ServiceAccount peut-il lister les pods dans postgres ? --> yes
kubectl auth can-i list pods \
  --as=system:serviceaccount:postgres:mon-app \
  -n postgres

# Le ServiceAccount peut-il supprimer des pods ? --> no
kubectl auth can-i delete pods \
  --as=system:serviceaccount:postgres:mon-app \
  -n postgres

# Le ServiceAccount peut-il voir les logs ? --> yes
kubectl auth can-i get pods/log \
  --as=system:serviceaccount:postgres:mon-app \
  -n postgres

# Le ServiceAccount peut-il lister les pods dans un AUTRE namespace ? --> no
kubectl auth can-i list pods \
  --as=system:serviceaccount:postgres:mon-app \
  -n default

# Le ServiceAccount peut-il lister les nodes ? --> no (pas de ClusterRoleBinding)
kubectl auth can-i list nodes \
  --as=system:serviceaccount:postgres:mon-app
```

### 7. (Exercice) Creer un ClusterRoleBinding

Le ClusterRole `node-reader` existe mais n'est lie a aucune identite. Creez un ClusterRoleBinding pour lier ce ClusterRole au ServiceAccount `mon-app` :

```bash
kubectl create clusterrolebinding read-nodes \
  --clusterrole=node-reader \
  --serviceaccount=postgres:mon-app
```

Verifiez ensuite :
```bash
# Maintenant le ServiceAccount peut lister les nodes --> yes
kubectl auth can-i list nodes \
  --as=system:serviceaccount:postgres:mon-app
```

## Formes imperatives (utiles pour la CKAD)

Les commandes imperatives sont plus rapides a taper lors des examens de certification :

```bash
# Creer un ServiceAccount
kubectl create serviceaccount mon-app -n postgres

# Creer un Role
kubectl create role pod-reader \
  --verb=get,list,watch \
  --resource=pods,pods/log \
  -n postgres

# Creer un RoleBinding
kubectl create rolebinding read-pods \
  --role=pod-reader \
  --serviceaccount=postgres:mon-app \
  -n postgres

# Creer un ClusterRole
kubectl create clusterrole node-reader \
  --verb=get,list,watch \
  --resource=nodes

# Creer un ClusterRoleBinding
kubectl create clusterrolebinding read-nodes \
  --clusterrole=node-reader \
  --serviceaccount=postgres:mon-app
```

## Commandes utiles

```bash
# Lister les Roles d'un namespace
kubectl get roles -n postgres

# Lister les RoleBindings d'un namespace
kubectl get rolebindings -n postgres

# Lister tous les ClusterRoles (attention, il y en a beaucoup par defaut)
kubectl get clusterroles

# Lister les ClusterRoleBindings
kubectl get clusterrolebindings

# Voir toutes les permissions d'un ServiceAccount
kubectl auth can-i --list \
  --as=system:serviceaccount:postgres:mon-app \
  -n postgres

# Verifier ses propres permissions
kubectl auth can-i --list -n postgres

# Lister les groupes d'API et les ressources
kubectl api-resources
```

## Troubleshooting

### `Error: serviceaccounts "mon-app" not found`
**Cause probable** : le ServiceAccount n'a pas ete cree ou a ete cree dans un autre namespace.
```bash
kubectl get serviceaccounts -n postgres
kubectl get serviceaccounts --all-namespaces | grep mon-app
```
**Solution** : appliquer `serviceaccount.yaml` ou verifier le namespace.

### `kubectl auth can-i` retourne `no` alors que le Role existe
**Cause probable** : le RoleBinding n'a pas ete cree, ou il reference un mauvais Role/ServiceAccount.
```bash
# Verifier que le RoleBinding existe
kubectl get rolebindings -n postgres

# Verifier les details du RoleBinding
kubectl describe rolebinding read-pods -n postgres
```
**Verifier que :**
- Le `subjects[].name` correspond exactement au nom du ServiceAccount
- Le `subjects[].namespace` correspond au namespace du ServiceAccount
- Le `roleRef.name` correspond au nom du Role

### Le Pod n'a pas les permissions attendues
**Cause probable** : le Pod n'utilise pas le bon ServiceAccount.
```bash
# Verifier quel ServiceAccount est utilise par le Pod
kubectl get pod <nom-du-pod> -n postgres -o jsonpath='{.spec.serviceAccountName}'
```
**Solution** : ajouter `serviceAccountName: mon-app` dans la spec du Pod.

### `Error: clusterroles.rbac.authorization.k8s.io "node-reader" is forbidden`
**Cause probable** : vous n'avez pas les droits d'administrateur pour creer des ClusterRoles.
```bash
# Verifier vos propres permissions
kubectl auth can-i create clusterroles
```
**Solution** : utiliser un contexte avec des droits administrateur.

### Le roleRef est immuable
**Symptome** : erreur lors de la modification d'un RoleBinding existant.
```
Error: roleRef cannot be updated
```
**Solution** : supprimer et recreer le RoleBinding :
```bash
kubectl delete rolebinding read-pods -n postgres
kubectl apply -f rolebinding.yaml
```

## Nettoyage

```bash
kubectl delete -f rolebinding.yaml
kubectl delete -f role.yaml
kubectl delete -f serviceaccount.yaml
kubectl delete -f clusterrole.yaml
# Si vous avez cree le ClusterRoleBinding en exercice :
kubectl delete clusterrolebinding read-nodes
```

## Pour aller plus loin

- [Documentation officielle Kubernetes : RBAC](https://kubernetes.io/docs/reference/access-authn-authz/rbac/)
- [Documentation officielle Kubernetes : ServiceAccounts](https://kubernetes.io/docs/concepts/security/service-accounts/)
- [Documentation officielle Kubernetes : Authorization Overview](https://kubernetes.io/docs/reference/access-authn-authz/authorization/)
- [API Groups Reference](https://kubernetes.io/docs/reference/using-api/)

**Suggestions d'amelioration :**
- Utiliser des `resourceNames` pour restreindre l'acces a des Pods specifiques (ex: `resourceNames: ["nginx", "postgres"]`)
- Creer un ClusterRole agrege en utilisant les labels `rbac.authorization.k8s.io/aggregate-to-*`
- Explorer les Roles predefinis (`view`, `edit`, `admin`, `cluster-admin`) fournis par Kubernetes
- Mettre en place un audit log pour tracer les acces RBAC
- Tester avec un outil comme `rakkess` pour visualiser les permissions sous forme de matrice

## QCM de revision

**Question 1** : Quelle est la difference entre un Role et un ClusterRole ?

- A) Un Role est plus puissant qu'un ClusterRole
- B) Un Role est limite a un namespace, un ClusterRole s'applique au cluster entier
- C) Un ClusterRole ne peut cibler que les Nodes
- D) Il n'y a pas de difference, ce sont des synonymes

<details>
<summary>Reponse</summary>
<b>B)</b> Un Role definit des permissions dans un namespace specifique. Un ClusterRole definit des permissions au niveau du cluster entier et peut cibler des ressources non-namespacees (nodes, persistentvolumes, etc.).
</details>

---

**Question 2** : Pourquoi ne faut-il pas utiliser le ServiceAccount `default` en production ?

- A) Le ServiceAccount `default` est supprime automatiquement apres 24h
- B) Le ServiceAccount `default` a des droits administrateur
- C) Il ne permet pas d'appliquer le principe du moindre privilege car il est partage par tous les Pods du namespace
- D) Le ServiceAccount `default` ne peut pas etre utilise avec les RoleBindings

<details>
<summary>Reponse</summary>
<b>C)</b> Le ServiceAccount <code>default</code> est partage par tous les Pods du namespace qui ne specifient pas de ServiceAccount. Toute permission accordee au <code>default</code> s'applique a tous ces Pods, ce qui viole le principe du moindre privilege.
</details>

---

**Question 3** : Que signifie `apiGroups: [""]` dans une regle RBAC ?

- A) La regle s'applique a toutes les API groups
- B) La regle cible le groupe core de l'API (pods, services, secrets, etc.)
- C) La regle est invalide, il faut toujours specifier un groupe
- D) La regle cible les ressources custom (CRDs)

<details>
<summary>Reponse</summary>
<b>B)</b> La chaine vide <code>""</code> designe le groupe core de l'API Kubernetes (<code>/api/v1</code>). Ce groupe contient les ressources fondamentales : pods, services, secrets, configmaps, namespaces, nodes, persistentvolumes, etc.
</details>

---

**Question 4** : Comment un RoleBinding peut-il referencer un ClusterRole ?

- A) C'est impossible, un RoleBinding ne peut referencer qu'un Role
- B) En mettant `roleRef.kind: ClusterRole` -- les permissions sont alors limitees au namespace du RoleBinding
- C) En mettant `roleRef.kind: ClusterRole` -- les permissions s'appliquent au cluster entier
- D) En creant d'abord un ClusterRoleBinding puis en le convertissant

<details>
<summary>Reponse</summary>
<b>B)</b> Un RoleBinding peut referencer un ClusterRole. Dans ce cas, les permissions du ClusterRole sont <b>restreintes au namespace</b> du RoleBinding. C'est une technique courante pour reutiliser un ClusterRole standard (comme <code>view</code> ou <code>edit</code>) dans differents namespaces.
</details>

---

**Question 5** : Quelle commande permet de verifier si un ServiceAccount peut effectuer une action ?

- A) `kubectl check permissions`
- B) `kubectl auth can-i <verbe> <ressource> --as=system:serviceaccount:<namespace>:<nom>`
- C) `kubectl rbac verify`
- D) `kubectl describe serviceaccount`

<details>
<summary>Reponse</summary>
<b>B)</b> La commande <code>kubectl auth can-i</code> avec l'option <code>--as</code> permet de simuler l'identite d'un ServiceAccount et de tester ses permissions. Le format complet de l'identite est <code>system:serviceaccount:&lt;namespace&gt;:&lt;nom&gt;</code>.
</details>

---

**Question 6** : Que se passe-t-il si on essaie de modifier le `roleRef` d'un RoleBinding existant ?

- A) La modification est appliquee normalement
- B) Kubernetes cree un nouveau RoleBinding automatiquement
- C) L'operation echoue car le roleRef est immuable
- D) Le RoleBinding est automatiquement supprime

<details>
<summary>Reponse</summary>
<b>C)</b> Le champ <code>roleRef</code> d'un RoleBinding est <b>immuable</b>. Pour changer le Role reference, il faut supprimer le RoleBinding existant et en creer un nouveau. Cette contrainte garantit la coherence des permissions.
</details>

---

**Question 7** : Un Role dans le namespace `postgres` autorise `get` sur les `pods`. Un ServiceAccount de ce namespace peut-il lire les Pods du namespace `default` avec cette seule permission ?

- A) Oui, les Roles s'appliquent a tous les namespaces
- B) Non, un Role est strictement limite a son namespace
- C) Oui, si le Pod est dans le namespace `default`
- D) Non, seuls les ClusterRoles peuvent lire des ressources

<details>
<summary>Reponse</summary>
<b>B)</b> Un Role est strictement limite a son namespace. Le ServiceAccount ne peut lire les Pods que dans le namespace <code>postgres</code>. Pour lire les Pods d'un autre namespace, il faudrait soit un RoleBinding dans ce namespace, soit un ClusterRoleBinding vers un ClusterRole adequat.
</details>
