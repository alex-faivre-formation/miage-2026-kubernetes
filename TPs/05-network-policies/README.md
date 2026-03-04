# TP05 - NetworkPolicy -- Isolation reseau des pods

## Introduction theorique

Par defaut, dans Kubernetes, **tous les Pods peuvent communiquer avec tous les autres Pods** du cluster, quel que soit leur namespace. C'est pratique pour le developpement mais represente un risque de securite majeur en production : si un Pod est compromis, l'attaquant peut acceder a tous les autres services, y compris les bases de donnees contenant des informations sensibles.

Les **NetworkPolicies** permettent de definir des regles de pare-feu au niveau des Pods. Elles controlent le trafic entrant (ingress) et sortant (egress) en fonction de criteres comme les labels des Pods, les namespaces et les ports.

### Le modele reseau de Kubernetes

Pour comprendre les NetworkPolicies, il faut d'abord comprendre le modele reseau de Kubernetes :

```
Cluster Kubernetes -- Reseau plat (flat network)
+----------------------------------------------------------------+
|                                                                |
|  Chaque Pod recoit une adresse IP unique                       |
|  Tout Pod peut joindre tout autre Pod par son IP               |
|                                                                |
|  Namespace: frontend          Namespace: backend               |
|  +------------------------+   +----------------------------+   |
|  |  Pod A: 10.244.1.10    |   |  Pod C: 10.244.2.20       |   |
|  |  Pod B: 10.244.1.11    |   |  Pod D (DB): 10.244.2.21  |   |
|  +------------------------+   +----------------------------+   |
|        |         |                   |          ^              |
|        |         +-------------------+          |              |
|        +----------------------------------------+              |
|           TOUT LE MONDE PEUT PARLER A TOUT LE MONDE            |
+----------------------------------------------------------------+
```

Ce comportement est appele **"flat network"** : il n'y a pas d'isolation entre les namespaces ou les Pods par defaut. Les namespaces fournissent une isolation **logique** (nommage), pas une isolation **reseau**.

### Principe du Zero Trust

La bonne pratique de securite est d'appliquer un modele **Zero Trust** :
1. **Bloquer tout le trafic par defaut** (deny-all) -- ne faire confiance a personne
2. **Ouvrir uniquement les flux strictement necessaires** (whitelist) -- autoriser au cas par cas

```
AVANT NetworkPolicy :                 APRES NetworkPolicy :

+--------+     +--------+            +--------+     +--------+
|Frontend| --> |  Base   |            |Frontend| --> |  Base   |
+--------+     | donnees |            +--------+  v  | donnees |
               +--------+                  AUTORISE  +--------+
+--------+         ^                  +--------+         x
|Attaquant| -------+                  |Attaquant| -------+
+--------+                            +--------+    BLOQUE
```

### Fonctionnement des NetworkPolicies

Les NetworkPolicies fonctionnent comme des regles de pare-feu **additives** :
- Sans aucune NetworkPolicy, tout le trafic est autorise
- Des qu'une NetworkPolicy selectionne un Pod (via `podSelector`), **seul le trafic explicitement autorise** par les regles est permis
- Plusieurs NetworkPolicies peuvent s'appliquer au meme Pod : leurs regles sont combinees en **OU** (union)

```
NetworkPolicy s'applique a un Pod ?
    |
    +-- NON --> Tout le trafic est autorise (comportement par defaut)
    |
    +-- OUI --> Seul le trafic matche par les regles ingress/egress
                est autorise. Tout le reste est BLOQUE.
                |
                +-- Plusieurs policies sur le meme Pod ?
                    --> Les regles sont combinees (union/OR)
```

### Ingress vs Egress

Les NetworkPolicies peuvent controler deux directions de trafic :

```
                  INGRESS                      EGRESS
                (trafic entrant)            (trafic sortant)

            Source --> [Pod cible]          [Pod source] --> Destination

Qui appelle ?   Un autre Pod,              Le Pod protege
                un Service, Internet       par la policy

Controle :      D'ou peut-on               Vers ou le Pod
                contacter ce Pod ?         peut-il envoyer
                                           du trafic ?
```

- **Ingress** : controle qui peut envoyer du trafic **vers** le Pod selectionne
- **Egress** : controle vers ou le Pod selectionne peut envoyer du trafic

Dans ce TP, nous ne travaillons qu'avec l'**Ingress** (trafic entrant).

### AND vs OR dans les selectors

C'est l'un des pieges les plus courants des NetworkPolicies. La difference se joue sur **un seul tiret** en YAML :

```yaml
# CAS 1 : AND (meme entree "from" -- PAS de tiret devant podSelector)
# Le pod DOIT etre dans le namespace "frontend"
# ET DOIT avoir le label "app: frontend"
ingress:
  - from:
      - namespaceSelector:
          matchLabels:
            kubernetes.io/metadata.name: frontend
        podSelector:           # <-- PAS de tiret = meme element = AND
          matchLabels:
            app: frontend

# CAS 2 : OR (entrees separees dans "from" -- TIRET devant podSelector)
# Le pod doit etre dans le namespace "frontend"
# OU avoir le label "app: frontend" (dans N'IMPORTE quel namespace !)
ingress:
  - from:
      - namespaceSelector:
          matchLabels:
            kubernetes.io/metadata.name: frontend
      - podSelector:           # <-- Tiret = element separe = OR
          matchLabels:
            app: frontend
```

Visualisation de la difference :

```
CAS 1 (AND) : securise                CAS 2 (OR) : DANGEREUX

Namespace frontend:                    Namespace frontend:
  Pod app=frontend --> AUTORISE          Pod app=frontend --> AUTORISE
  Pod app=malware  --> BLOQUE            Pod app=malware  --> AUTORISE (!)

Namespace default:                     Namespace default:
  Pod app=frontend --> BLOQUE            Pod app=frontend --> AUTORISE (!)
  Pod app=malware  --> BLOQUE            Pod app=malware  --> BLOQUE
```

Le CAS 2 est souvent une erreur : il autorise **tous** les Pods du namespace `frontend` (pas seulement ceux avec `app: frontend`), ET aussi tous les Pods avec le label `app: frontend` de **n'importe quel namespace**.

### CNI et support des NetworkPolicies

Les NetworkPolicies sont une ressource Kubernetes standard, mais leur **enforcement** depend du plugin reseau (CNI -- Container Network Interface) :

| CNI | Support NetworkPolicy | Notes |
|-----|----------------------|-------|
| Calico | Oui (complet) | Le plus repandu pour les NetworkPolicies |
| Cilium | Oui (complet + extensions) | Supporte aussi le filtrage L7 (HTTP) |
| Weave Net | Oui | Support basique |
| Flannel | Non | Ne supporte PAS les NetworkPolicies |
| CNI par defaut minikube | Non | Utiliser `--cni=calico` |

**Piege important :** Si votre CNI ne supporte pas les NetworkPolicies, les manifests sont acceptes par l'API server sans erreur mais sont **ignores silencieusement**. Aucun avertissement n'est affiche. Vos Pods restent ouverts a tout trafic alors que vous pensez etre protege.

## Objectifs

- Bloquer tout le trafic entrant par defaut (deny-all)
- Autoriser uniquement le trafic legitime (whitelist)
- Comprendre la combinaison des selectors (AND vs OR)
- Tester l'isolation reseau entre les Pods

## Prerequis

- Un cluster Kubernetes fonctionnel
- `kubectl` installe et configure
- Namespace `postgres` existant avec des pods PostgreSQL (TP02)
- **CNI compatible** : Calico, Cilium ou Weave Net

> Pour activer les NetworkPolicies sur minikube :
> ```bash
> minikube start --cni=calico
> ```

## Architecture deployee

```
Cluster Kubernetes
+------------------------------------------------------------------+
|                                                                  |
|  Namespace: frontend                                             |
|  +------------------------------------------------------------+ |
|  |                                                            | |
|  |  Pod (label: app=frontend)                                 | |
|  |       |                                                    | |
|  +-------|----------------------------------------------------+ |
|          |                                                      |
|          | AUTORISE par "allow-frontend-to-db"                  |
|          | TCP 5432 uniquement                                  |
|          |                                                      |
|  Namespace: postgres                                             |
|  +-------|----------------------------------------------------+ |
|  |       v                                                    | |
|  |  Pod (label: app=postgresdb) <--- port 5432 ouvert        | |
|  |       x                                                    | |
|  |       | BLOQUE par "default-deny-ingress"                  | |
|  |       x                                                    | |
|  |  Tout autre trafic entrant (autre namespace, autre pod,    | |
|  |  autre port) est REFUSE                                    | |
|  |                                                            | |
|  |  Autres Pods du namespace :                                | |
|  |  TOUT trafic entrant BLOQUE (deny-all s'applique)         | |
|  |                                                            | |
|  +------------------------------------------------------------+ |
|                                                                  |
|  Namespace: default (ou autre)                                   |
|  +------------------------------------------------------------+ |
|  |  Pod quelconque --> postgres:5432 = BLOQUE                 | |
|  +------------------------------------------------------------+ |
|                                                                  |
+------------------------------------------------------------------+
```

## Fichiers et explication detaillee

### `default-deny-ingress.yaml` -- Bloquer tout le trafic entrant

```yaml
apiVersion: networking.k8s.io/v1    # API pour les NetworkPolicies
kind: NetworkPolicy
metadata:
  name: default-deny-ingress
  namespace: postgres               # S'applique au namespace postgres
spec:
  podSelector: {}                   # {} = TOUS les pods du namespace
  policyTypes:
    - Ingress                       # Controle le trafic ENTRANT
                                    # Pas de section "ingress:" = tout est bloque
```

**Champs importants :**
- `apiVersion: networking.k8s.io/v1` : les NetworkPolicies font partie du groupe `networking.k8s.io`. Elles ne sont pas dans le core API group.
- `podSelector: {}` : le selecteur vide (`{}`) selectionne **tous les Pods** du namespace. C'est la cle pour creer un deny-all.
- `policyTypes: [Ingress]` : indique que cette policy controle le trafic entrant. Sans cette section, Kubernetes pourrait inferer les types depuis les regles presentes.
- **Absence de section `ingress:`** : c'est volontaire et c'est la que reside toute la subtilite. En declarant `policyTypes: [Ingress]` sans aucune regle `ingress:`, on indique que tout trafic entrant est bloque. Aucune exception n'est definie.
- **Trafic sortant (egress)** : n'est pas affecte par cette policy. Les Pods peuvent toujours initier des connexions sortantes (DNS, appels HTTP, etc.).
- **Trafic intra-Pod** : le trafic sur `localhost` (127.0.0.1) n'est jamais affecte par les NetworkPolicies.

**Patron deny-all pour l'egress :**
```yaml
# Pour bloquer AUSSI le trafic sortant :
spec:
  podSelector: {}
  policyTypes:
    - Ingress
    - Egress
```

### `allow-frontend-to-db.yaml` -- Autoriser un flux specifique

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-frontend-to-db
  namespace: postgres
spec:
  podSelector:                       # A QUELS pods s'applique la regle
    matchLabels:
      app: postgresdb               # Cible uniquement les pods PostgreSQL
  policyTypes:
    - Ingress
  ingress:
    - from:                          # D'OU vient le trafic autorise
        - namespaceSelector:         # Condition 1 (AND avec podSelector)
            matchLabels:
              kubernetes.io/metadata.name: frontend
          podSelector:               # Condition 2 (AND avec namespaceSelector)
            matchLabels:
              app: frontend
      ports:                         # Sur QUELS ports
        - protocol: TCP
          port: 5432                 # Uniquement le port PostgreSQL
```

**Champs importants :**
- `podSelector.matchLabels.app: postgresdb` : cette policy ne protege que les Pods avec le label `app: postgresdb`. Les autres Pods du namespace ne sont pas affectes par cette regle specifique (mais restent proteges par le deny-all general).
- `namespaceSelector` et `podSelector` dans **la meme entree** (pas de tiret devant `podSelector`) : c'est un **ET logique**. Le trafic est autorise uniquement si le Pod source est dans le namespace `frontend` **ET** a le label `app: frontend`.
- `kubernetes.io/metadata.name: frontend` : ce label est automatiquement ajoute par Kubernetes a chaque namespace (depuis la version 1.21). Il contient le nom du namespace. C'est le moyen le plus fiable de selectionner un namespace par son nom.
- `ports.port: 5432` : restreint l'acces au port PostgreSQL uniquement. Meme un Pod frontend autorise ne peut pas acceder a d'autres ports du Pod DB (ex: port de monitoring).
- `protocol: TCP` : PostgreSQL utilise TCP. Si non specifie, la regle s'applique a TCP par defaut. Les autres valeurs possibles sont `UDP` et `SCTP`.

**Comment les deux policies interagissent :**
```
Pod postgresdb dans le namespace postgres :
  1. "default-deny-ingress" s'applique (podSelector: {}) --> TOUT bloque
  2. "allow-frontend-to-db" s'applique (podSelector: app=postgresdb)
     --> autorise le trafic depuis frontend:app=frontend sur TCP/5432
  3. Resultat = union des deux : seul le trafic frontend:5432 passe

Autre Pod dans le namespace postgres :
  1. "default-deny-ingress" s'applique (podSelector: {}) --> TOUT bloque
  2. "allow-frontend-to-db" ne s'applique PAS (pas le label app=postgresdb)
  3. Resultat : tout le trafic entrant est bloque
```

## Deploiement pas a pas

### 1. Verifier les prerequis

```bash
# Verifier que le CNI supporte les NetworkPolicies
kubectl get pods -n kube-system | grep -E "calico|cilium|weave"
```

Sortie attendue (exemple avec Calico) :
```
calico-kube-controllers-xxx   1/1     Running   0          1d
calico-node-xxx               1/1     Running   0          1d
```

Si rien n'apparait, votre CNI ne supporte probablement pas les NetworkPolicies.

```bash
# Verifier que le namespace postgres existe
kubectl get namespace postgres
```

### 2. Appliquer le deny-all

```bash
kubectl apply -f default-deny-ingress.yaml
```

Verifier :
```bash
kubectl get networkpolicies -n postgres
```

Sortie attendue :
```
NAME                   POD-SELECTOR   AGE
default-deny-ingress   <none>         5s
```

Note : `POD-SELECTOR` affiche `<none>` pour un selecteur vide `{}`, ce qui signifie "tous les Pods".

### 3. Autoriser le frontend vers la DB

```bash
kubectl apply -f allow-frontend-to-db.yaml
```

Verifier :
```bash
kubectl get networkpolicies -n postgres
```

Sortie attendue :
```
NAME                     POD-SELECTOR       AGE
default-deny-ingress     <none>             2m
allow-frontend-to-db     app=postgresdb     5s
```

Pour voir les details de la regle :
```bash
kubectl describe networkpolicy allow-frontend-to-db -n postgres
```

Sortie attendue :
```
Name:         allow-frontend-to-db
Namespace:    postgres
Spec:
  PodSelector:     app=postgresdb
  Allowing ingress traffic:
    To Port: 5432/TCP
    From:
      NamespaceSelector: kubernetes.io/metadata.name=frontend
      PodSelector: app=frontend
  Not affecting egress traffic
  Policy Types: Ingress
```

### 4. Tester l'isolation (exercice pratique)

Creez un environnement de test pour verifier que les NetworkPolicies fonctionnent :

```bash
# Creer le namespace frontend si necessaire
kubectl create namespace frontend

# Lancer un pod avec le LABEL frontend (autorise)
kubectl run test-frontend --image=busybox -n frontend \
  --labels="app=frontend" -- sleep 3600

# Attendre que le Pod soit Running
kubectl wait --for=condition=Ready pod/test-frontend -n frontend --timeout=60s

# Tester la connexion vers PostgreSQL (devrait reussir si un Pod DB existe)
kubectl exec -n frontend test-frontend -- \
  nc -zv -w 3 postgresdb.postgres.svc.cluster.local 5432

# Lancer un pod SANS le bon label (bloque)
kubectl run test-attacker --image=busybox -n frontend \
  --labels="app=malware" -- sleep 3600

# Attendre que le Pod soit Running
kubectl wait --for=condition=Ready pod/test-attacker -n frontend --timeout=60s

# Tester la connexion (devrait timeout apres 3 secondes)
kubectl exec -n frontend test-attacker -- \
  nc -zv -w 3 postgresdb.postgres.svc.cluster.local 5432
```

Le premier test (avec le label `app=frontend`) devrait reussir. Le second (sans le bon label) devrait echouer avec un timeout.

```bash
# Nettoyage des Pods de test
kubectl delete pod test-frontend test-attacker -n frontend
```

## Commandes utiles

```bash
# Lister les NetworkPolicies d'un namespace
kubectl get networkpolicies -n postgres

# Voir les details d'une NetworkPolicy
kubectl describe networkpolicy default-deny-ingress -n postgres

# Exporter une NetworkPolicy en YAML (pour debug)
kubectl get networkpolicy allow-frontend-to-db -n postgres -o yaml

# Verifier les labels d'un namespace
kubectl get namespace frontend --show-labels

# Verifier les labels d'un Pod
kubectl get pods -n frontend --show-labels

# Lister les NetworkPolicies de tous les namespaces
kubectl get networkpolicies --all-namespaces
```

## Bonnes pratiques

1. **Commencer par un deny-all** sur chaque namespace contenant des donnees sensibles
2. **Ouvrir uniquement les flux necessaires** avec des regles specifiques
3. **Documenter chaque regle** : ajouter des annotations expliquant pourquoi le flux est necessaire
4. **Tester les regles** : verifier que le trafic non autorise est bien bloque
5. **Utiliser les deux directions** : `Ingress` ET `Egress` pour un controle complet
6. **Ne pas oublier le DNS** : si vous bloquez le trafic egress, autorisez le port 53 (UDP/TCP) vers `kube-system`, sinon la resolution DNS ne fonctionnera plus
7. **Utiliser AND (pas OR)** pour les selectors `from` : toujours combiner `namespaceSelector` et `podSelector` dans la meme entree
8. **Versionner les NetworkPolicies** : les traiter comme du code dans Git

## Troubleshooting

### Les NetworkPolicies ne bloquent rien
**Cause probable** : votre CNI ne supporte pas les NetworkPolicies.
```bash
# Verifier le CNI utilise
kubectl get pods -n kube-system | grep -E "calico|cilium|weave"

# Si rien n'apparait, le CNI par defaut ne supporte pas les NetworkPolicies
# Sur minikube :
minikube delete
minikube start --cni=calico
```
**Important** : les manifests sont acceptes sans erreur meme si le CNI ne les supporte pas. L'absence d'erreur ne garantit pas que les regles sont appliquees.

### Le trafic est bloque alors qu'il devrait etre autorise

**Cause probable 1** : confusion AND/OR dans les selectors.
```bash
kubectl describe networkpolicy allow-frontend-to-db -n postgres
# Verifier dans la section "Allowing ingress traffic" :
# - "NamespaceSelector" et "PodSelector" doivent etre sur la MEME ligne
#   (= AND) et non sur des lignes separees (= OR)
```

**Cause probable 2** : le namespace source n'a pas le bon label.
```bash
kubectl get namespace frontend --show-labels
# Doit contenir : kubernetes.io/metadata.name=frontend
# Ce label est ajoute automatiquement depuis Kubernetes 1.21
```

**Cause probable 3** : le Pod source n'a pas le bon label.
```bash
kubectl get pods -n frontend --show-labels
# Doit contenir : app=frontend
```

**Cause probable 4** : le Pod cible n'a pas le bon label.
```bash
kubectl get pods -n postgres --show-labels
# Le Pod DB doit avoir : app=postgresdb
```

### Le trafic est bloque dans les deux sens
**Cause** : vous avez peut-etre aussi bloque le trafic egress sans le vouloir.
```bash
kubectl describe networkpolicy -n postgres
# Verifier que "Policy Types" ne contient que "Ingress" (pas "Egress")
```

### Le DNS ne fonctionne plus apres avoir ajoute une policy egress
**Cause** : le trafic DNS (port 53) est aussi bloque par la policy egress.
**Solution** : ajouter une regle autorisant le DNS :
```yaml
egress:
  - to:
      - namespaceSelector:
          matchLabels:
            kubernetes.io/metadata.name: kube-system
    ports:
      - protocol: UDP
        port: 53
      - protocol: TCP
        port: 53
```

### La NetworkPolicy ne s'applique pas a certains Pods
**Cause probable** : le `podSelector` de la NetworkPolicy ne matche pas les labels des Pods concernes.
```bash
# Comparer les labels du Pod et le selector de la policy
kubectl get pods -n postgres --show-labels
kubectl describe networkpolicy allow-frontend-to-db -n postgres | grep PodSelector
```

## Nettoyage

```bash
kubectl delete -f allow-frontend-to-db.yaml
kubectl delete -f default-deny-ingress.yaml
# Si vous avez cree des Pods de test :
kubectl delete pod test-frontend test-attacker -n frontend --ignore-not-found
```

## Pour aller plus loin

- [Documentation officielle Kubernetes : NetworkPolicies](https://kubernetes.io/docs/concepts/services-networking/network-policies/)
- [Network Policy Editor (outil visuel)](https://editor.networkpolicy.io/) -- outil interactif pour concevoir des NetworkPolicies
- [Documentation Calico : NetworkPolicies](https://docs.tigera.io/calico/latest/network-policy/)
- [Documentation Cilium : NetworkPolicies](https://docs.cilium.io/en/stable/security/policy/)
- [NetworkPolicy Recipes](https://github.com/ahmetb/kubernetes-network-policy-recipes) -- exemples courants de NetworkPolicies

**Suggestions d'amelioration :**
- Ajouter une NetworkPolicy egress pour controler le trafic sortant des Pods (avec autorisation DNS)
- Implementer une politique `deny-all` pour le trafic egress egalement
- Tester avec des NetworkPolicies Cilium-specific pour des fonctionnalites avancees (filtrage L7 HTTP, DNS-based policies)
- Utiliser des `ipBlock` pour autoriser/bloquer des plages d'IP specifiques (ex: empecher l'acces a des IP internes sensibles)
- Mettre en place du logging reseau pour auditer les flux bloques (avec Calico ou Cilium)
- Combiner RBAC (TP04) et NetworkPolicies pour une defense en profondeur

## QCM de revision

**Question 1** : Que se passe-t-il si aucune NetworkPolicy n'est definie dans un namespace ?

- A) Tout le trafic est bloque par defaut
- B) Seul le trafic intra-namespace est autorise
- C) Tout le trafic entrant et sortant est autorise
- D) Le namespace est isole du reste du cluster

<details>
<summary>Reponse</summary>
<b>C)</b> Sans aucune NetworkPolicy, Kubernetes autorise tout le trafic par defaut (ingress et egress). Les Pods peuvent communiquer librement avec tous les autres Pods du cluster, quel que soit leur namespace. C'est le comportement "flat network".
</details>

---

**Question 2** : Dans la regle `from`, quelle est la difference entre mettre `namespaceSelector` et `podSelector` dans la **meme entree** vs dans des **entrees separees** ?

- A) Il n'y a pas de difference
- B) Meme entree = ET (AND), entrees separees = OU (OR)
- C) Meme entree = OU (OR), entrees separees = ET (AND)
- D) Les entrees separees ne sont pas valides

<details>
<summary>Reponse</summary>
<b>B)</b> C'est un point crucial et un piege frequent. Quand <code>namespaceSelector</code> et <code>podSelector</code> sont dans la meme entree (sans tiret devant <code>podSelector</code>), les conditions sont combinees en <b>ET</b> : le Pod doit satisfaire les deux criteres. Quand ils sont dans des entrees separees (avec un tiret devant chacun), les conditions sont combinees en <b>OU</b> : satisfaire l'une ou l'autre suffit. La version OR est generalement une erreur de securite.
</details>

---

**Question 3** : Que se passe-t-il si votre CNI (ex: Flannel) ne supporte pas les NetworkPolicies ?

- A) Les manifests NetworkPolicy sont rejetes avec une erreur
- B) Les manifests sont acceptes et appliques correctement
- C) Les manifests sont acceptes mais les regles sont ignorees silencieusement
- D) Le cluster refuse de demarrer

<details>
<summary>Reponse</summary>
<b>C)</b> C'est un piege important. Les NetworkPolicies sont des ressources Kubernetes standard, donc l'API server les accepte toujours sans erreur. Mais leur enforcement depend du CNI. Si le CNI ne les supporte pas (Flannel, par exemple), les regles sont stockees dans etcd mais <b>jamais appliquees</b>. Aucun avertissement n'est emis. Votre cluster semble protege mais ne l'est pas.
</details>

---

**Question 4** : Que fait `podSelector: {}` dans une NetworkPolicy ?

- A) Ne selectionne aucun Pod
- B) Selectionne les Pods sans labels
- C) Selectionne tous les Pods du namespace
- D) Selectionne tous les Pods du cluster

<details>
<summary>Reponse</summary>
<b>C)</b> Le selecteur vide <code>{}</code> matche <b>tous les Pods</b> du namespace de la NetworkPolicy. C'est utilise dans les regles deny-all pour bloquer tout le trafic vers tous les Pods du namespace. Attention : il selectionne les Pods du namespace de la policy, pas du cluster entier.
</details>

---

**Question 5** : Pourquoi faut-il autoriser le port 53 quand on ajoute une policy egress deny-all ?

- A) Le port 53 est utilise par Kubernetes pour la communication inter-noeuds
- B) Le port 53 est le port DNS. Sans lui, les Pods ne peuvent plus resoudre les noms de services
- C) Le port 53 est le port de l'API server
- D) Le port 53 est utilise pour le health check des Pods

<details>
<summary>Reponse</summary>
<b>B)</b> Le port 53 (UDP et TCP) est utilise par le DNS. Le service <code>kube-dns</code> (ou CoreDNS) ecoute sur ce port dans le namespace <code>kube-system</code>. Si une policy egress bloque le trafic sortant sans exception pour le DNS, les Pods ne pourront plus resoudre les noms de services (ex: <code>postgresdb.postgres.svc.cluster.local</code>) et toutes les communications par nom echoueront.
</details>

---

**Question 6** : Deux NetworkPolicies s'appliquent au meme Pod. La premiere autorise le trafic depuis le namespace `frontend`. La seconde autorise le trafic depuis le namespace `monitoring`. Quel est le resultat ?

- A) Seule la derniere policy appliquee est active
- B) Le trafic est autorise depuis `frontend` ET `monitoring` (union des regles)
- C) Le trafic est autorise uniquement si le Pod est dans `frontend` ET `monitoring` en meme temps
- D) Les policies entrent en conflit et sont toutes les deux desactivees

<details>
<summary>Reponse</summary>
<b>B)</b> Les NetworkPolicies sont <b>additives</b>. Quand plusieurs policies s'appliquent au meme Pod, leurs regles sont combinees en <b>union (OU)</b>. Le trafic autorise par l'une ou l'autre des policies est permis. Il n'y a jamais de conflit entre les policies : elles ne peuvent qu'ajouter des autorisations, jamais en retirer.
</details>

---

**Question 7** : Un Pod dans le namespace `default` essaie de se connecter au port 5432 d'un Pod `app=postgresdb` dans le namespace `postgres`. La NetworkPolicy `allow-frontend-to-db` autorise uniquement les Pods `app=frontend` du namespace `frontend`. Que se passe-t-il ?

- A) La connexion est autorisee car le port 5432 est ouvert
- B) La connexion est bloquee car le Pod source n'est ni dans le bon namespace ni avec le bon label
- C) La connexion est autorisee car le deny-all ne s'applique pas aux connexions inter-namespaces
- D) La connexion echoue avec un message d'erreur RBAC

<details>
<summary>Reponse</summary>
<b>B)</b> La connexion est bloquee. Le deny-all bloque tout le trafic entrant vers les Pods du namespace <code>postgres</code>. La seule exception est la policy <code>allow-frontend-to-db</code> qui autorise uniquement les Pods avec le label <code>app=frontend</code> provenant du namespace <code>frontend</code>. Un Pod du namespace <code>default</code> ne satisfait aucune de ces conditions, donc la connexion est refusee (timeout silencieux, pas de message d'erreur).
</details>
