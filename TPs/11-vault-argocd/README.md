# TP11 - Vault via ArgoCD -- GitOps pour la gestion des secrets

## Introduction theorique

Ce TP deploie **HashiCorp Vault** en mode HA (High Availability) dans Kubernetes en utilisant **ArgoCD** au lieu de la commande `helm install` manuelle (TP10). Cela applique le principe GitOps : l'etat desire de Vault est declare dans Git et ArgoCD s'assure que le cluster correspond.

### Pourquoi deployer Vault via ArgoCD ?

Le TP10 installait Vault avec `helm install` -- une commande imperative. Si quelqu'un modifie la configuration de Vault dans le cluster, il n'y a aucun mecanisme pour detecter ou corriger la derive. Avec ArgoCD :

```
  TP10 (Helm imperatif)              TP11 (ArgoCD/GitOps)
  ====================              ====================

  Admin --> helm install             Admin --> git push
               |                                  |
               v                                  v
          Cluster K8s               Git --> ArgoCD --> Cluster K8s
          (pas de suivi)            (reconciliation continue)
```

**Avantages du deploiement GitOps :**
- **Reproductibilite** : la configuration exacte est dans Git, pas dans l'historique shell d'un admin
- **Audit** : chaque changement est un commit Git avec auteur et message
- **Self-healing** : si Vault est modifie manuellement, ArgoCD restaure l'etat Git
- **Rollback** : revenir a une version precedente = `git revert`

### ArgoCD et les charts Helm

ArgoCD peut deployer des charts Helm de deux facons :

| Methode | Description | Usage |
|---------|-------------|-------|
| `source.path` | Pointe vers un dossier contenant des manifests YAML ou un chart local | Manifests en Git |
| `source.chart` | Pointe vers un chart dans un registre Helm distant | Charts publics (Vault, Prometheus, etc.) |

Dans ce TP, on utilise `source.chart` car le chart Vault est maintenu par HashiCorp et disponible sur `https://helm.releases.hashicorp.com`.

### Architecture Vault HA avec Raft

```
Namespace: vault
+-----------------------------------------------------------+
|                                                           |
|  +-------------+  +-------------+  +-------------+       |
|  | vault-0     |  | vault-1     |  | vault-2     |       |
|  | (Leader)    |  | (Standby)   |  | (Standby)   |       |
|  |             |  |             |  |             |       |
|  | Raft Storage|  | Raft Storage|  | Raft Storage|       |
|  | /vault/data |  | /vault/data |  | /vault/data |       |
|  +------+------+  +------+------+  +------+------+       |
|         |                |                |               |
|         +---------- Raft Consensus -------+               |
|                          |                                |
|                   vault-internal                          |
|                   (Service headless)                      |
|                                                           |
|  +---------------------------------------------------+   |
|  | vault (Service ClusterIP :8200)                    |   |
|  +---------------------------------------------------+   |
+-----------------------------------------------------------+
         ^
         | Deploye et surveille par
         |
  Namespace: argocd
  +----------------------------+
  | Application: vault         |
  | Source: hashicorp/vault    |
  | (chart Helm distant)       |
  +----------------------------+
```

### Le processus d'Unseal

Vault utilise l'algorithme de **Shamir's Secret Sharing** pour proteger sa cle maitre. Au demarrage, Vault est "sealed" (scelle) et ne peut ni lire ni ecrire de secrets.

```
  Vault demarre
       |
       v
  +----------+     operator init      +----------+
  | Sealed   | ----------------------> | Cles     |
  | (inutile)|  (genere les cles)     | generees |
  +----------+                         +----------+
       |                                    |
       v                                    v
  operator unseal               key-shares=1, key-threshold=1
  (fournir la cle)              (1 seule cle necessaire)
       |
       v
  +----------+
  | Unsealed |
  | (operationnel)
  +----------+
```

**Pour un TP**, on utilise `key-shares=1, key-threshold=1` (une seule cle). En production, on utilise typiquement `key-shares=5, key-threshold=3` (3 cles sur 5 necessaires).

**Important** : Vault sera "Degraded" dans ArgoCD tant qu'il n'est pas unseal. C'est un comportement attendu car ArgoCD voit les pods comme "not Ready".

## Objectifs

- Deployer Vault en mode HA via une Application ArgoCD (au lieu de `helm install`)
- Comprendre la difference entre deploiement imperatif et declaratif/GitOps
- Initialiser et unseal un cluster Vault
- Observer le comportement d'ArgoCD avec un chart Helm distant

## Prerequis

- Un cluster Kubernetes fonctionnel (minikube)
- ArgoCD installe et operationnel (TP08)
- `kubectl`, `jq` installes

## Fichiers et explication detaillee

### `application.yaml` -- Application ArgoCD pour Vault

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: vault
  namespace: argocd                    # Les Applications ArgoCD vivent dans ce namespace
spec:
  project: default
  source:
    chart: vault                       # Nom du chart Helm (pas un path Git !)
    repoURL: https://helm.releases.hashicorp.com  # Registre Helm HashiCorp
    targetRevision: 0.28.1             # Version du chart (pas de Vault)
    helm:
      releaseName: vault               # Nom de la release Helm
      values: |                        # Values Helm inline (equivalent de values.yaml)
        server:
          affinity: ""                 # Desactive l'anti-affinity (obligatoire sur minikube, 1 seul noeud)
          ha:
            enabled: true              # Mode High Availability
            replicas: 3                # 3 replicas pour le quorum Raft
            raft:
              enabled: true            # Stockage Raft integre (pas besoin de Consul)
              ...
          dataStorage:
            storageClass: standard     # StorageClass minikube
  destination:
    server: https://kubernetes.default.svc
    namespace: vault
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

**Points cles :**
- `source.chart` au lieu de `source.path` : on reference un chart Helm distant
- `affinity: ""` : **obligatoire sur minikube** car il n'y a qu'un seul noeud et l'anti-affinity par defaut empeche les 3 pods de se scheduler sur le meme noeud
- `helm.values` : les values Helm sont injectees inline dans l'Application (pas de fichier values.yaml separe)

### `setup.sh` -- Script d'initialisation

Ce script :
1. Applique l'Application ArgoCD
2. Attend que les pods Vault soient Running
3. Initialise Vault (`operator init`)
4. Unseal le noeud leader (vault-0)
5. Joint les noeuds secondaires au cluster Raft
6. Unseal les noeuds secondaires
7. Sauvegarde les cles dans `cluster-keys.json` (fichier local, pas dans Git)

## Deploiement pas a pas

### 1. Deployer Vault via ArgoCD

```bash
# Depuis le dossier TPs/11-vault-argocd/
./setup.sh
```

Ou manuellement :

```bash
kubectl apply -f application.yaml
```

### 2. Observer dans ArgoCD

```bash
# L'application sera "Degraded" car Vault n'est pas encore unseal
kubectl get application vault -n argocd
```

Sortie attendue (avant unseal) :
```
NAME    SYNC STATUS   HEALTH STATUS
vault   Synced        Degraded
```

### 3. Verifier les pods

```bash
kubectl get pods -n vault
```

Sortie attendue (avant unseal) :
```
NAME                                    READY   STATUS    RESTARTS   AGE
vault-0                                 0/1     Running   0          2m
vault-1                                 0/1     Running   0          2m
vault-2                                 0/1     Running   0          2m
vault-agent-injector-xxxxxxxxx-xxxxx    1/1     Running   0          2m
```

**0/1 Running** : les pods sont Running mais pas Ready (pas unseal).

### 4. Initialiser et unseal (si fait manuellement)

```bash
# Initialisation
kubectl exec vault-0 -n vault -- vault operator init \
  -key-shares=1 -key-threshold=1 -format=json > cluster-keys.json

# Unseal vault-0
VAULT_UNSEAL_KEY=$(jq -r ".unseal_keys_b64[0]" cluster-keys.json)
kubectl exec vault-0 -n vault -- vault operator unseal $VAULT_UNSEAL_KEY

# Joindre et unseal vault-1 et vault-2
kubectl exec vault-1 -n vault -- vault operator raft join http://vault-0.vault-internal:8200
kubectl exec vault-1 -n vault -- vault operator unseal $VAULT_UNSEAL_KEY

kubectl exec vault-2 -n vault -- vault operator raft join http://vault-0.vault-internal:8200
kubectl exec vault-2 -n vault -- vault operator unseal $VAULT_UNSEAL_KEY
```

### 5. Verifier le resultat

```bash
# Statut de Vault (doit afficher "Sealed: false")
kubectl exec vault-0 -n vault -- vault status

# Pods (doivent etre 1/1 Ready)
kubectl get pods -n vault

# Application ArgoCD (doit etre Synced)
kubectl get application vault -n argocd
```

## Troubleshooting

### Les pods Vault restent en Pending

**Cause probable** : pas de StorageClass `standard` ou pas assez de PVs disponibles.
```bash
kubectl get sc
kubectl get pv
kubectl describe pod vault-0 -n vault
```
**Solution** : verifier que minikube fournit la StorageClass `standard` (par defaut).

### L'Application ArgoCD reste en "Degraded"

**Cause probable** : Vault n'est pas unseal. C'est **le comportement attendu** avant l'etape d'init/unseal.
```bash
kubectl exec vault-0 -n vault -- vault status
# Si "Sealed: true", executez le setup.sh ou les commandes d'unseal
```

### Erreur "raft: no known peers" sur vault-1/vault-2

**Cause probable** : les noeuds secondaires n'ont pas rejoint le cluster Raft.
```bash
kubectl exec vault-1 -n vault -- vault operator raft join http://vault-0.vault-internal:8200
```

### Les 3 pods ne se schedulent pas (anti-affinity)

**Cause probable** : `affinity: ""` n'est pas dans les values.
```bash
kubectl describe pod vault-1 -n vault | grep -A5 "Events"
# "0/1 nodes are available: 1 node(s) didn't match pod anti-affinity rules"
```
**Solution** : verifier que `affinity: ""` est bien present dans les values Helm de l'Application.

### cluster-keys.json perdu

Si vous perdez `cluster-keys.json`, vous ne pouvez plus unseal Vault. La seule solution est de reinstaller :
```bash
kubectl delete application vault -n argocd
kubectl delete pvc -l app.kubernetes.io/name=vault -n vault
kubectl delete ns vault
# Puis redeployer
kubectl apply -f application.yaml
```

## Nettoyage

```bash
# Supprimer l'Application (et toutes les ressources Vault)
kubectl delete application vault -n argocd

# Supprimer les PVCs (donnees Raft)
kubectl delete pvc -l app.kubernetes.io/name=vault -n vault

# Supprimer le namespace
kubectl delete ns vault
```

## Pour aller plus loin

- [Vault Helm Chart documentation](https://developer.hashicorp.com/vault/docs/platform/k8s/helm)
- [ArgoCD Helm Chart support](https://argo-cd.readthedocs.io/en/stable/user-guide/helm/)
- [Vault Auto-Unseal](https://developer.hashicorp.com/vault/docs/concepts/seal#auto-unseal) avec un KMS cloud
- Configurer l'auto-unseal avec un transit engine pour eviter l'intervention manuelle

## QCM de revision

**Question 1** : Quelle est la difference entre `source.path` et `source.chart` dans une Application ArgoCD ?

- A) `source.path` pointe vers un chemin dans un repo Git, `source.chart` vers un chart dans un registre Helm
- B) `source.path` est pour YAML, `source.chart` est pour Kustomize
- C) Il n'y a pas de difference, les deux sont interchangeables
- D) `source.chart` est deprecie en faveur de `source.path`

<details>
<summary>Reponse</summary>
<b>A)</b> <code>source.path</code> reference un chemin dans un depot Git (manifests YAML ou chart local), tandis que <code>source.chart</code> reference un chart dans un registre Helm distant (ex: <code>https://helm.releases.hashicorp.com</code>).
</details>

---

**Question 2** : Pourquoi `affinity: ""` est-il necessaire dans les values Vault sur minikube ?

- A) Pour activer l'affinite de noeud
- B) Pour desactiver l'anti-affinity par defaut qui empeche les 3 pods de tourner sur le meme noeud
- C) Pour configurer l'affinite de zone (zone-aware)
- D) Ce n'est pas necessaire, c'est optionnel

<details>
<summary>Reponse</summary>
<b>B)</b> Le chart Vault definit par defaut une <code>podAntiAffinity</code> qui empeche deux pods Vault de tourner sur le meme noeud. Sur minikube (1 seul noeud), cela empeche le scheduling des replicas 2 et 3. <code>affinity: ""</code> desactive cette regle.
</details>

---

**Question 3** : Pourquoi Vault apparait-il comme "Degraded" dans ArgoCD apres le deploiement ?

- A) Parce qu'il y a une erreur de configuration dans le chart Helm
- B) Parce que les pods sont Running mais pas Ready (Vault est sealed et les readiness probes echouent)
- C) Parce qu'ArgoCD ne supporte pas les StatefulSets
- D) Parce que le namespace vault n'est pas cree

<details>
<summary>Reponse</summary>
<b>B)</b> Avant l'operation d'unseal, Vault est scelle (sealed). Les readiness probes echouent car Vault refuse les requetes en mode sealed. ArgoCD voit des pods "not Ready" et rapporte un etat "Degraded". C'est un comportement attendu qui se resout apres l'unseal.
</details>

---

**Question 4** : Que contient le fichier `cluster-keys.json` genere par `vault operator init` ?

- A) La configuration du cluster Kubernetes
- B) Les cles d'unseal et le root token de Vault
- C) Les certificats TLS de Vault
- D) Les credentials ArgoCD

<details>
<summary>Reponse</summary>
<b>B)</b> <code>cluster-keys.json</code> contient les <code>unseal_keys_b64</code> (cles pour unsealer Vault) et le <code>root_token</code> (token d'administration). Ce fichier est critique et ne doit JAMAIS etre committe dans Git.
</details>

---

**Question 5** : Quel est le role de la commande `vault operator raft join` executee sur vault-1 et vault-2 ?

- A) Elle initialise un nouveau cluster Raft independant
- B) Elle joint le noeud au cluster Raft existant (leader vault-0) pour la replication
- C) Elle copie les donnees de vault-0 vers les autres noeuds
- D) Elle configure le load balancing entre les noeuds

<details>
<summary>Reponse</summary>
<b>B)</b> <code>vault operator raft join</code> indique au noeud secondaire de rejoindre le cluster Raft dont le leader est vault-0. Une fois joint, le noeud recevra les donnees repliquees et pourra devenir leader si vault-0 tombe en panne.
</details>
