# TP08 - ArgoCD -- GitOps dans le cluster

## Introduction theorique

Ce TP introduit **ArgoCD**, l'outil de reference pour le deploiement continu (CD) dans Kubernetes selon le paradigme **GitOps**. GitOps est un modele operationnel ou l'etat desire de l'infrastructure est stocke dans un depot Git, et un agent dans le cluster s'assure en permanence que l'etat reel correspond a l'etat declare dans Git.

### Qu'est-ce que le GitOps ?

Le GitOps repose sur quatre principes fondamentaux :

1. **Declaratif** : l'ensemble du systeme est decrit de maniere declarative (manifests YAML, charts Helm, etc.)
2. **Versionne et immutable** : l'etat desire est stocke dans Git, qui fournit un historique complet et la possibilite de revenir en arriere
3. **Tire automatiquement** (pull-based) : un agent dans le cluster tire les changements depuis Git, au lieu que le CI pousse vers le cluster
4. **Reconciliation continue** : un controller compare en boucle l'etat reel du cluster avec l'etat desire dans Git et corrige les ecarts

```
  Modele Push (CI/CD classique)            Modele Pull (GitOps)
  ===========================              ====================

  Dev --> Git --> CI --> kubectl apply      Dev --> Git --> ArgoCD (dans le cluster)
                    |                                         |
                    v                                         v
               Cluster K8s                              Cluster K8s
                                                     (reconciliation continue)
```

### Pourquoi GitOps plutot que kubectl apply dans un pipeline ?

| Approche | Avantages | Inconvenients |
|----------|-----------|---------------|
| `kubectl apply` dans CI | Simple a mettre en place | Necessite des credentials cluster dans le CI, pas de detection de derive |
| GitOps (ArgoCD) | Pas de credentials externes, detection de derive, audit Git, rollback facile | Complexite initiale d'installation |

### Qu'est-ce qu'ArgoCD ?

ArgoCD est un controller Kubernetes qui implemente le GitOps. Il surveille un ou plusieurs depots Git et synchronise automatiquement les ressources Kubernetes avec ce qui est declare dans Git.

```
+---------------------------------------------------------------+
|                     Cluster Kubernetes                         |
|                                                                |
|  Namespace: argocd                                             |
|  +----------------------------------------------------------+ |
|  |                                                          | |
|  |  +------------------+   +---------------------------+    | |
|  |  | argocd-server    |   | argocd-repo-server        |    | |
|  |  | (API + UI)       |   | (clone Git, rend templates)|   | |
|  |  +------------------+   +---------------------------+    | |
|  |                                                          | |
|  |  +------------------+   +---------------------------+    | |
|  |  | app-controller   |   | argocd-redis              |    | |
|  |  | (reconciliation) |   | (cache partage)           |    | |
|  |  +------------------+   +---------------------------+    | |
|  |                                                          | |
|  |  +------------------+   +---------------------------+    | |
|  |  | dex-server       |   | applicationset-controller |    | |
|  |  | (SSO/OIDC)       |   | (generation dynamique)    |    | |
|  |  +------------------+   +---------------------------+    | |
|  +----------------------------------------------------------+ |
|                                                                |
|  Namespace: postgres  (gere par ArgoCD)                        |
|  +----------------------------------------------------------+ |
|  |  ConfigMap + Secret + PV/PVC + Deployment + Service       | |
|  +----------------------------------------------------------+ |
+---------------------------------------------------------------+
          ^
          |  Compare en boucle (toutes les 3 min par defaut)
          v
  +-------------------+
  |  Depot Git        |
  |  TPs/02-postgres/ |
  |  (source of truth)|
  +-------------------+
```

### La boucle de reconciliation

ArgoCD fonctionne en boucle continue :

```
   +--------+     +----------+     +-----------+     +----------+
   | Clone  | --> | Compare  | --> | Etat =    | --> | Rien a   |
   | Git    |     | Git vs   |     | Synced ?  |     | faire    |
   +--------+     | Cluster  |     +-----------+     +----------+
                  +----------+            |
                                     Non (OutOfSync)
                                          |
                                          v
                                   +-----------+
                                   | Sync auto | (si automated)
                                   | ou alerte |
                                   +-----------+
```

### La CRD Application

ArgoCD introduit une **Custom Resource Definition** (CRD) appelee `Application`. C'est l'objet central qui definit :
- **Source** : ou trouver les manifests (repo Git, branche, chemin)
- **Destination** : ou les deployer (cluster, namespace)
- **SyncPolicy** : comment gerer la synchronisation

## Objectifs

- Installer ArgoCD dans le cluster
- Creer une Application ArgoCD pour synchroniser des manifests depuis Git
- Observer la detection de derive et le self-healing
- Comprendre le workflow GitOps
- Manipuler la CLI ArgoCD

## Prerequis

- Un cluster Kubernetes fonctionnel (minikube, Docker Desktop, etc.)
- `kubectl` installe et configure
- Un depot Git contenant les manifests Kubernetes (le dossier `TPs/02-postgres/` de ce repo)

## Architecture deployee

```
Cluster Kubernetes
+-------------------------------------------------------------------+
|                                                                   |
|  Namespace: argocd                                                |
|  +-------------------------------------------------------------+ |
|  |  argocd-server  argocd-repo-server  argocd-app-controller   | |
|  |  argocd-redis   argocd-dex-server   applicationset-ctrl     | |
|  +-------------------------------------------------------------+ |
|                          |                                        |
|                          | surveille & synchronise                |
|                          v                                        |
|  Namespace: postgres  (cree automatiquement par ArgoCD)           |
|  +-------------------------------------------------------------+ |
|  |  +----------+ +--------+ +----+ +-----+ +------------+      | |
|  |  | ConfigMap| | Secret | | PV | | PVC | | Deployment |      | |
|  |  +----------+ +--------+ +----+ +-----+ | postgresdb |      | |
|  |                                          +------------+      | |
|  |                                          +------------+      | |
|  |                                          | Service    |      | |
|  |                                          +------------+      | |
|  +-------------------------------------------------------------+ |
+-------------------------------------------------------------------+
          ^
          | Git poll (3 min) ou webhook
          |
  +-------+---------+
  | GitHub repo     |
  | miage-2026-     |
  | kubernetes      |
  | /TPs/02-postgres|
  +-----------------+
```

## Fichiers et explication detaillee

### `application.yaml` -- CRD Application ArgoCD

```yaml
apiVersion: argoproj.io/v1alpha1      # API ArgoCD (Custom Resource)
kind: Application                      # Type : Application ArgoCD
metadata:
  name: postgresdb                     # Nom de l'application dans ArgoCD
  namespace: argocd                    # DOIT etre dans le namespace argocd
spec:
  project: default                     # Projet ArgoCD (default = sans restriction)
  source:
    repoURL: https://github.com/alex-faivre-formation/miage-2026-kubernetes.git
    targetRevision: main               # Branche Git a suivre
    path: TPs/02-postgres              # Chemin dans le repo contenant les manifests
  destination:
    server: https://kubernetes.default.svc  # Cluster cible (ici, le cluster local)
    namespace: postgres                     # Namespace de deploiement
  syncPolicy:
    automated:                         # Synchronisation automatique activee
      prune: true                      # Supprime les ressources retirees de Git
      selfHeal: true                   # Corrige les modifications manuelles
    syncOptions:
      - CreateNamespace=true           # Cree le namespace s'il n'existe pas
```

**Champs importants :**

- `apiVersion: argoproj.io/v1alpha1` : il s'agit d'une CRD (Custom Resource Definition) ajoutee par ArgoCD. Elle n'existe pas dans un cluster Kubernetes standard -- elle est creee lors de l'installation d'ArgoCD.
- `metadata.namespace: argocd` : les Applications ArgoCD doivent resider dans le namespace `argocd` (ou celui configure pour ArgoCD).
- `spec.project: default` : les projets ArgoCD permettent de restreindre les sources, destinations et ressources autorisees. Le projet `default` n'a aucune restriction.
- `spec.source.repoURL` : l'URL du depot Git. ArgoCD supporte HTTPS et SSH. **Important** : le depot doit etre **public**, ou si le depot est prive, il faut configurer les credentials dans ArgoCD (via la CLI `argocd repo add` ou l'interface web dans Settings > Repositories).
- `spec.source.targetRevision: main` : la branche, le tag ou le commit a suivre. Utiliser `HEAD` pour toujours suivre la branche par defaut.
- `spec.source.path` : le chemin relatif dans le repo. ArgoCD appliquera **tous les fichiers YAML trouves dans ce repertoire** (et ses sous-repertoires). **Attention** : si le dossier contient des variantes de Deployment (comme le dossier `examples/` du TP02 qui contient `deployment-with-secret.yaml` et `deployment-secret-volume.yaml`), ArgoCD essaiera de les appliquer toutes, ce qui creera des conflits (plusieurs Deployments avec le meme nom). C'est pour cela que les variantes sont placees dans le sous-dossier `examples/` : ArgoCD les deploiera aussi. Si vous ne voulez deployer qu'une seule variante, deplacez les autres hors du path source ou utilisez un `.argocd-include`/`.argocd-exclude`.
- `spec.destination.server` : `https://kubernetes.default.svc` designe le cluster local (celui ou ArgoCD est installe). Pour un cluster distant, on utiliserait son URL API.
- `spec.syncPolicy.automated` : active la synchronisation automatique. Sans ce bloc, il faudrait synchroniser manuellement via la CLI ou l'interface web.
- `prune: true` : si un fichier YAML est supprime de Git, la ressource correspondante sera supprimee du cluster. Sans `prune`, les ressources orphelines restent.
- `selfHeal: true` : si quelqu'un modifie manuellement une ressource dans le cluster (ex: `kubectl edit`), ArgoCD detecte la derive et restaure l'etat Git. C'est le coeur du GitOps.
- `CreateNamespace=true` : ArgoCD creera le namespace `postgres` s'il n'existe pas. Sans cette option, le sync echoue si le namespace est absent.

## Composants ArgoCD

| Composant | Role |
|-----------|------|
| `argocd-server` | API REST, interface web, endpoint gRPC. Point d'entree pour les utilisateurs. |
| `argocd-application-controller` | Boucle de reconciliation GitOps : compare l'etat Git avec l'etat cluster toutes les 3 minutes. |
| `argocd-repo-server` | Clone les depots Git, rend les templates (Helm, Kustomize, plain YAML). Met en cache les manifests. |
| `argocd-redis` | Cache partage entre les composants pour les performances. |
| `argocd-dex-server` | Serveur d'authentification SSO/OIDC (GitHub, GitLab, LDAP, Okta). |
| `argocd-applicationset-controller` | Genere dynamiquement des Applications depuis des templates (utile pour le multi-cluster ou multi-tenant). |

## SyncPolicy en detail

| Option | Effet | Defaut |
|--------|-------|--------|
| `automated` | Synchronisation automatique quand Git change | Desactive (sync manuelle) |
| `prune: true` | Supprime les ressources retirees de Git | `false` |
| `selfHeal: true` | Corrige les modifications manuelles dans le cluster | `false` |
| `CreateNamespace=true` | Cree le namespace cible s'il n'existe pas | `false` |
| `Replace=true` | Utilise `kubectl replace` au lieu de `kubectl apply` | `false` |
| `ServerSideApply=true` | Utilise le Server-Side Apply de Kubernetes | `false` |

## Deploiement pas a pas

### 1. Installer ArgoCD

```bash
kubectl create namespace argocd

kubectl apply -n argocd \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
```

Sortie attendue :
```
namespace/argocd created
customresourcedefinition.apiextensions.k8s.io/applications.argoproj.io created
customresourcedefinition.apiextensions.k8s.io/applicationsets.argoproj.io created
customresourcedefinition.apiextensions.k8s.io/appprojects.argoproj.io created
serviceaccount/argocd-application-controller created
...
```

### 2. Attendre que tous les pods soient prets

```bash
kubectl wait --for=condition=Ready pods --all -n argocd --timeout=180s
```

Sortie attendue :
```
pod/argocd-application-controller-0 condition met
pod/argocd-dex-server-xxxxxxxxx-xxxxx condition met
pod/argocd-redis-xxxxxxxxx-xxxxx condition met
pod/argocd-repo-server-xxxxxxxxx-xxxxx condition met
pod/argocd-server-xxxxxxxxx-xxxxx condition met
```

```bash
kubectl get pods -n argocd
```

Sortie attendue :
```
NAME                                                READY   STATUS    RESTARTS   AGE
argocd-application-controller-0                     1/1     Running   0          2m
argocd-dex-server-xxxxxxxxx-xxxxx                   1/1     Running   0          2m
argocd-redis-xxxxxxxxx-xxxxx                        1/1     Running   0          2m
argocd-repo-server-xxxxxxxxx-xxxxx                  1/1     Running   0          2m
argocd-server-xxxxxxxxx-xxxxx                       1/1     Running   0          2m
argocd-applicationset-controller-xxxxxxxxx-xxxxx    1/1     Running   0          2m
```

### 3. Acceder a l'interface web

```bash
# Port-forward vers le serveur ArgoCD
kubectl port-forward svc/argocd-server 8080:443 -n argocd
```

Ouvrir : **https://localhost:8080** (accepter le certificat auto-signe)

```bash
# Recuperer le mot de passe admin initial
kubectl get secret argocd-initial-admin-secret \
  -n argocd \
  -o jsonpath="{.data.password}" | base64 -d
```

Login : `admin` / mot de passe recupere ci-dessus.

### 4. Installer la CLI ArgoCD (optionnel)

```bash
# macOS
brew install argocd

# Se connecter
argocd login localhost:8080 \
  --username admin \
  --password <mot-de-passe> \
  --insecure
```

### 5. Deployer l'Application

**Option A -- Manifest YAML (declaratif, recommande)**

```bash
kubectl apply -f application.yaml
```

Sortie attendue :
```
application.argoproj.io/postgresdb created
```

**Option B -- CLI ArgoCD**

```bash
argocd app create postgresdb \
  --repo https://github.com/alex-faivre-formation/miage-2026-kubernetes.git \
  --path TPs/02-postgres \
  --dest-server https://kubernetes.default.svc \
  --dest-namespace postgres \
  --sync-policy automated \
  --auto-prune \
  --self-heal
```

### 6. Verifier le deploiement

```bash
# Etat de l'application
argocd app get postgresdb
```

Sortie attendue :
```
Name:               argocd/postgresdb
Project:            default
Server:             https://kubernetes.default.svc
Namespace:          postgres
URL:                https://localhost:8080/applications/postgresdb
Repo:               https://github.com/alex-faivre-formation/miage-2026-kubernetes.git
Target:             main
Path:               TPs/02-postgres
SyncWindow:         Sync Allowed
Sync Policy:        Automated (Prune)
Sync Status:        Synced to main (abc1234)
Health Status:      Healthy

GROUP  KIND            NAMESPACE  NAME         STATUS  HEALTH
       Namespace       postgres   postgres     Synced
       ConfigMap       postgres   credentials  Synced
       Secret          postgres   db-creds     Synced
       PersistentVolume           pv           Synced
       PersistentVolumeClaim postgres pvc      Synced  Healthy
apps   Deployment      postgres   postgresdb   Synced  Healthy
       Service         postgres   postgresdb   Synced  Healthy
```

```bash
# Verifier que les ressources sont bien creees dans le namespace postgres
kubectl get all -n postgres
```

## Exercice -- Simuler une derive GitOps

C'est l'exercice fondateur pour comprendre le GitOps :

### Etape 1 : Modifier manuellement une ressource dans le cluster

```bash
kubectl set env deployment/postgresdb POSTGRES_DB=wrongdb -n postgres
```

### Etape 2 : Observer la detection de derive

```bash
argocd app get postgresdb
```

Sortie attendue (dans les secondes/minutes qui suivent) :
```
Sync Status:  OutOfSync
Health Status: Progressing
```

### Etape 3 : Observer le self-heal

Si `selfHeal: true` est active (c'est le cas dans notre `application.yaml`), ArgoCD corrige automatiquement la derive :

```bash
# Attendre la reconciliation (jusqu'a 3 minutes)
kubectl rollout status deployment/postgresdb -n postgres
```

### Etape 4 : Verifier la restauration

```bash
kubectl get deployment postgresdb -n postgres -o jsonpath='{.spec.template.spec.containers[0].env}' | python3 -m json.tool
```

La variable `POSTGRES_DB` est revenue a sa valeur d'origine definie dans Git.

### Etape 5 (variante) : Desactiver le self-heal et observer

Modifiez `application.yaml` en commentant `selfHeal: true`, reappliquez, puis refaites une modification manuelle. Cette fois, ArgoCD detecte la derive mais ne corrige pas :

```bash
argocd app get postgresdb
# STATUS: OutOfSync -- mais pas de correction automatique

# Synchroniser manuellement
argocd app sync postgresdb
```

## Commandes utiles

```bash
# Etat de l'application
argocd app get postgresdb

# Synchronisation manuelle
argocd app sync postgresdb

# Historique des synchronisations
argocd app history postgresdb

# Ressources gerees par l'application
argocd app resources postgresdb

# Voir les differences entre Git et le cluster
argocd app diff postgresdb

# Logs de l'application
argocd app logs postgresdb

# Lister toutes les applications
argocd app list
```

## Troubleshooting

### L'Application reste en `Unknown` ou `OutOfSync`

**Cause probable** : ArgoCD ne peut pas acceder au depot Git (repo prive, URL incorrecte).
```bash
# Verifier les logs du repo-server
kubectl logs -l app.kubernetes.io/name=argocd-repo-server -n argocd

# Verifier la configuration du repo
argocd repo list
```
**Solution** : verifier l'URL du repo. Pour un repo prive, ajouter les credentials :
```bash
argocd repo add https://github.com/... --username <user> --password <token>
```

### Le namespace cible n'est pas cree

**Cause probable** : `CreateNamespace=true` n'est pas dans les `syncOptions`.
```bash
kubectl get ns postgres
# Error from server (NotFound): namespaces "postgres" not found
```
**Solution** : ajouter `- CreateNamespace=true` dans `syncOptions` du fichier `application.yaml`.

### Le mot de passe admin ne fonctionne pas

**Cause probable** : le secret initial a ete supprime apres la premiere connexion.
```bash
kubectl get secret argocd-initial-admin-secret -n argocd
# Error from server (NotFound)
```
**Solution** : reinitialiser le mot de passe via la CLI :
```bash
argocd account update-password
```

### Les pods ArgoCD sont en CrashLoopBackOff

**Cause probable** : ressources insuffisantes sur le cluster.
```bash
kubectl describe pod -l app.kubernetes.io/part-of=argocd -n argocd
# Chercher "Insufficient memory" ou "Insufficient cpu"
```
**Solution** : augmenter les ressources du cluster ou reduire les requests ArgoCD.

### Le self-heal ne fonctionne pas

**Cause probable** : `selfHeal` n'est pas active ou le delai de reconciliation n'est pas ecoule.
```bash
# Verifier la syncPolicy
kubectl get application postgresdb -n argocd -o yaml | grep -A5 syncPolicy
```
**Solution** : le cycle de reconciliation par defaut est de 3 minutes. Attendre ou forcer un refresh :
```bash
argocd app get postgresdb --refresh
```

## Nettoyage

```bash
# Supprimer l'application (et toutes les ressources qu'elle gere)
argocd app delete postgresdb --cascade

# Ou via kubectl
kubectl delete application postgresdb -n argocd

# Supprimer ArgoCD
kubectl delete namespace argocd
```

**Note** : l'option `--cascade` (par defaut) supprime aussi les ressources dans le namespace `postgres`. Sans cascade (`--cascade=false`), seule l'Application ArgoCD est supprimee, les ressources restent.

## Pour aller plus loin

- [Documentation officielle ArgoCD](https://argo-cd.readthedocs.io/)
- [ArgoCD Best Practices](https://argo-cd.readthedocs.io/en/stable/user-guide/best_practices/)
- [Principes GitOps par OpenGitOps](https://opengitops.dev/)
- [ArgoCD ApplicationSets](https://argo-cd.readthedocs.io/en/stable/user-guide/application-set/) pour le multi-cluster

**Suggestions d'amelioration :**
- Configurer un webhook GitHub pour declencher la synchronisation instantanement au lieu d'attendre le polling
- Utiliser un `AppProject` dedie avec des restrictions de source et destination
- Configurer l'authentification SSO via Dex (GitHub, GitLab, OIDC)
- Ajouter des notifications Slack/Teams via argocd-notifications
- Explorer ArgoCD Image Updater pour automatiser les mises a jour d'images Docker

## QCM de revision

**Question 1** : Quelle est la difference fondamentale entre le modele GitOps (pull) et le modele CI/CD classique (push) ?

- A) GitOps utilise Git tandis que le CI/CD classique utilise SVN
- B) En GitOps, un agent dans le cluster tire les changements depuis Git ; en push, le CI pousse les changements vers le cluster
- C) GitOps ne supporte que Kubernetes tandis que le CI/CD classique supporte toute infrastructure
- D) Il n'y a pas de difference fondamentale, c'est une question de preference

<details>
<summary>Reponse</summary>
<b>B)</b> En GitOps, l'agent (ArgoCD) est deploye dans le cluster et tire (pull) les manifests depuis Git. En modele push, le pipeline CI/CD execute <code>kubectl apply</code> depuis l'exterieur du cluster, ce qui necessite des credentials cluster dans le CI.
</details>

---

**Question 2** : Que se passe-t-il si `selfHeal: true` est active et qu'un operateur modifie manuellement un Deployment via `kubectl edit` ?

- A) La modification est conservee car kubectl a priorite sur ArgoCD
- B) ArgoCD detecte la derive et restaure l'etat defini dans Git
- C) ArgoCD supprime le Deployment et le recree
- D) ArgoCD passe l'application en erreur et arrete la synchronisation

<details>
<summary>Reponse</summary>
<b>B)</b> Le self-heal compare en boucle l'etat du cluster avec Git. Toute modification manuelle est detectee comme une derive (OutOfSync) et ArgoCD reapplique les manifests Git pour restaurer l'etat desire. Le Deployment n'est pas supprime/recree, il est reconcilie.
</details>

---

**Question 3** : Quel est le role du champ `prune: true` dans la syncPolicy ?

- A) Il supprime les anciens ReplicaSets apres un rolling update
- B) Il supprime du cluster les ressources qui ont ete retirees de Git
- C) Il nettoie les logs des pods termines
- D) Il supprime les images Docker inutilisees sur les noeuds

<details>
<summary>Reponse</summary>
<b>B)</b> Le pruning supprime du cluster les ressources Kubernetes dont les manifests ont ete supprimes du depot Git. Sans <code>prune: true</code>, ces ressources deviennent orphelines et restent dans le cluster indefiniment.
</details>

---

**Question 4** : Pourquoi l'Application ArgoCD doit-elle etre creee dans le namespace `argocd` ?

- A) C'est une convention, elle peut etre creee n'importe ou
- B) Le controller ArgoCD ne surveille que les Applications dans son propre namespace par defaut
- C) Le namespace argocd a des permissions RBAC speciales
- D) Kubernetes impose cette restriction pour les CRDs

<details>
<summary>Reponse</summary>
<b>B)</b> Par defaut, l'application-controller ArgoCD ne surveille les CRDs Application que dans le namespace ou il est installe (<code>argocd</code>). Cela peut etre modifie via la configuration d'ArgoCD, mais c'est le comportement par defaut.
</details>

---

**Question 5** : Quel composant ArgoCD est responsable du clonage des depots Git et du rendu des templates ?

- A) argocd-server
- B) argocd-application-controller
- C) argocd-repo-server
- D) argocd-redis

<details>
<summary>Reponse</summary>
<b>C)</b> Le <code>argocd-repo-server</code> est le composant qui clone les depots Git, met en cache les manifests et effectue le rendu des templates (Helm, Kustomize, plain YAML). Le controller utilise ensuite ces manifests rendus pour la comparaison.
</details>

---

**Question 6** : Que signifie `spec.destination.server: https://kubernetes.default.svc` ?

- A) C'est l'URL du serveur ArgoCD
- B) C'est l'URL du depot Git
- C) C'est le cluster Kubernetes local (celui ou ArgoCD est installe)
- D) C'est un cluster distant enregistre dans ArgoCD

<details>
<summary>Reponse</summary>
<b>C)</b> <code>https://kubernetes.default.svc</code> est l'adresse interne de l'API server Kubernetes, accessible depuis l'interieur du cluster. Cela indique a ArgoCD de deployer les ressources dans le meme cluster ou il est installe.
</details>

---

**Question 7** : Quel est le cycle de reconciliation par defaut d'ArgoCD ?

- A) 30 secondes
- B) 1 minute
- C) 3 minutes
- D) 10 minutes

<details>
<summary>Reponse</summary>
<b>C)</b> Par defaut, ArgoCD compare l'etat Git avec le cluster toutes les 3 minutes (configurable via le parametre <code>timeout.reconciliation</code> dans le ConfigMap <code>argocd-cm</code>). Les webhooks Git permettent une detection quasi-instantanee.
</details>
