# TP12 - External Secrets Operator -- Synchronisation Vault vers Kubernetes

## Introduction theorique

Ce TP installe **External Secrets Operator (ESO)**, un operateur Kubernetes qui synchronise automatiquement les secrets depuis des sources externes (Vault, AWS Secrets Manager, Azure Key Vault, etc.) vers des Secrets Kubernetes natifs.

### Le probleme : comment connecter Vault a Kubernetes ?

Vault stocke les secrets de maniere securisee, mais les applications Kubernetes ont besoin de **Secrets Kubernetes natifs** pour acceder aux credentials (via `envFrom`, volumes, etc.). Il faut un mecanisme pour synchroniser les deux :

```
  +----------+     Synchronisation      +-------------------+
  |          |   automatique (ESO)      |                   |
  |  Vault   | -----------------------> | Secret Kubernetes  |
  |  (source |                          | (consomme par les  |
  |   de     |                          |  pods)             |
  |  verite) |                          |                   |
  +----------+                          +-------------------+
       ^                                        |
       |                                        v
  Admin ecrit                             Pod lit
  les secrets                             les secrets
  dans Vault                              via envFrom/volume
```

### Qu'est-ce qu'External Secrets Operator ?

ESO introduit trois CRDs principales :

```
+---------------------------------------------------------------------+
|                    External Secrets Operator                          |
|                                                                      |
|  CRDs:                                                               |
|                                                                      |
|  +-------------------------+    +--------------------------------+   |
|  | SecretStore             |    | ClusterSecretStore             |   |
|  | (namespace-scoped)      |    | (cluster-wide)                 |   |
|  | Connexion au provider   |    | Connexion au provider          |   |
|  | pour UN namespace       |    | pour TOUS les namespaces       |   |
|  +-------------------------+    +--------------------------------+   |
|                                                                      |
|  +-------------------------+                                         |
|  | ExternalSecret          |                                         |
|  | (namespace-scoped)      |                                         |
|  | Mappe un secret Vault   |                                         |
|  | vers un Secret K8s      |                                         |
|  +-------------------------+                                         |
+---------------------------------------------------------------------+
```

| CRD | Scope | Role |
|-----|-------|------|
| `SecretStore` | Namespace | Definit la connexion a un provider de secrets (ex: Vault) pour un namespace |
| `ClusterSecretStore` | Cluster | Meme chose mais accessible depuis tous les namespaces |
| `ExternalSecret` | Namespace | Declare quel secret recuperer depuis le store et comment le mapper vers un Secret K8s |

### Pourquoi ClusterSecretStore plutot que SecretStore ?

Dans ce TP, on utilise un `ClusterSecretStore` car :
- **Un seul Vault** pour tout le cluster
- **Plusieurs namespaces** auront besoin d'acceder aux secrets (TP13, et potentiellement d'autres)
- Evite de dupliquer la configuration de connexion dans chaque namespace

```
  ClusterSecretStore "vault-backend"
  (accessible depuis tous les namespaces)
          |
          +--- Namespace: integration  --> ExternalSecret --> Secret K8s
          |
          +--- Namespace: staging      --> ExternalSecret --> Secret K8s
          |
          +--- Namespace: production   --> ExternalSecret --> Secret K8s
```

### Methode d'authentification : Token

ESO supporte plusieurs methodes d'authentification vers Vault :

| Methode | Complexite | Usage |
|---------|-----------|-------|
| **Token** | Simple | TPs, dev (ce TP) |
| Kubernetes Auth | Moyenne | Production (recommande) |
| AppRole | Moyenne | CI/CD, automatisation |

On utilise l'auth par **token** pour simplifier le TP. Le root token de Vault est stocke dans un Secret Kubernetes `vault-token` dans le namespace `external-secrets`.

## Objectifs

- Deployer External Secrets Operator via ArgoCD
- Configurer un ClusterSecretStore connecte a Vault
- Activer le moteur de secrets KV v2 dans Vault
- Verifier la connectivite entre ESO et Vault

## Prerequis

- Un cluster Kubernetes fonctionnel (minikube)
- ArgoCD installe et operationnel (TP08)
- Vault deploye et unseal (TP11)
- `kubectl`, `jq` installes

## Architecture deployee

```
Cluster Kubernetes
+-------------------------------------------------------------------+
|                                                                   |
|  Namespace: vault                                                 |
|  +-------------------------------------------------------------+ |
|  | vault-0, vault-1, vault-2 (HA/Raft, unsealed)               | |
|  | Secret Engine: kv-v2 (path: secret/)                         | |
|  +-------------------------------------------------------------+ |
|                          ^                                        |
|                          | Lit les secrets via HTTP API            |
|                          |                                        |
|  Namespace: external-secrets                                      |
|  +-------------------------------------------------------------+ |
|  | external-secrets (controller)                                | |
|  | external-secrets-webhook                                     | |
|  | external-secrets-cert-controller                             | |
|  |                                                              | |
|  | Secret: vault-token (contient le root token Vault)           | |
|  +-------------------------------------------------------------+ |
|                                                                   |
|  Ressource cluster-wide:                                          |
|  +-------------------------------------------------------------+ |
|  | ClusterSecretStore: vault-backend                            | |
|  | Provider: Vault (http://vault.vault.svc:8200)                | |
|  | Auth: Token (reference vault-token secret)                   | |
|  +-------------------------------------------------------------+ |
+-------------------------------------------------------------------+
```

## Fichiers et explication detaillee

### `application.yaml` -- Application ArgoCD pour ESO

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: external-secrets
  namespace: argocd
spec:
  source:
    chart: external-secrets           # Chart ESO depuis le registre officiel
    repoURL: https://charts.external-secrets.io
    targetRevision: 0.10.7
    helm:
      values: |
        installCRDs: true             # Installe les CRDs automatiquement
  destination:
    namespace: external-secrets
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

**Meme pattern que le TP11** : `source.chart` pointe vers un registre Helm distant. `installCRDs: true` est necessaire pour que les CRDs (SecretStore, ExternalSecret, etc.) soient creees.

### `cluster-secret-store.yaml` -- ClusterSecretStore

```yaml
apiVersion: external-secrets.io/v1beta1
kind: ClusterSecretStore
metadata:
  name: vault-backend
spec:
  provider:
    vault:
      server: "http://vault.vault.svc.cluster.local:8200"  # URL interne du service Vault
      path: "secret"                  # Path du moteur KV v2
      version: "v2"                   # Version du moteur KV
      auth:
        tokenSecretRef:
          name: "vault-token"         # Nom du Secret K8s contenant le token
          namespace: "external-secrets"  # Namespace du Secret
          key: "token"                # Cle dans le Secret
```

**Points cles :**
- `server` : URL du service Vault dans le cluster (`vault.vault.svc.cluster.local:8200`)
- `path: "secret"` : correspond au path ou on active le moteur KV v2 (`vault secrets enable -path=secret kv-v2`)
- `version: "v2"` : KV version 2 (supporte le versioning des secrets)
- `tokenSecretRef` : reference un Secret Kubernetes classique contenant le token d'authentification Vault

## Deploiement pas a pas

### 1. Executer le script de setup

```bash
# Depuis le dossier TPs/12-external-secrets/
./setup.sh
```

### 2. Ou deployer manuellement

```bash
# Deployer ESO via ArgoCD
kubectl apply -f application.yaml

# Attendre que les pods ESO soient prets
kubectl wait --for=condition=Ready pods -l app.kubernetes.io/name=external-secrets \
  -n external-secrets --timeout=180s

# Activer KV v2 dans Vault
ROOT_TOKEN=$(jq -r ".root_token" ../11-vault-argocd/cluster-keys.json)
kubectl exec vault-0 -n vault -- vault login "$ROOT_TOKEN"
kubectl exec vault-0 -n vault -- vault secrets enable -path=secret kv-v2

# Ecrire un secret de test
kubectl exec vault-0 -n vault -- vault kv put secret/test-secret \
  username="demo-user" password="demo-password"

# Creer le Secret contenant le token Vault
kubectl create secret generic vault-token \
  --from-literal=token="$ROOT_TOKEN" \
  -n external-secrets

# Appliquer le ClusterSecretStore
kubectl apply -f cluster-secret-store.yaml
```

### 3. Verifier

```bash
# Pods ESO
kubectl get pods -n external-secrets

# ClusterSecretStore (doit etre "Valid")
kubectl get clustersecretstore vault-backend

# Secret de test dans Vault
kubectl exec vault-0 -n vault -- vault kv get secret/test-secret
```

Sortie attendue pour le ClusterSecretStore :
```
NAME            AGE   STATUS   CAPABILITIES   READY
vault-backend   30s   Valid    ReadWrite      True
```

## Troubleshooting

### Le ClusterSecretStore est en "Invalid" ou "Error"

**Cause probable** : le token Vault est invalide ou le service Vault n'est pas accessible.
```bash
kubectl describe clustersecretstore vault-backend
# Chercher le message d'erreur dans les conditions
```

**Verifications :**
```bash
# Le secret vault-token existe-t-il ?
kubectl get secret vault-token -n external-secrets

# Le token est-il valide ?
ROOT_TOKEN=$(kubectl get secret vault-token -n external-secrets -o jsonpath='{.data.token}' | base64 -d)
kubectl exec vault-0 -n vault -- vault token lookup "$ROOT_TOKEN"

# Vault est-il accessible depuis le namespace external-secrets ?
kubectl run test-dns --rm -it --restart=Never --image=busybox -n external-secrets -- \
  wget -qO- http://vault.vault.svc.cluster.local:8200/v1/sys/health
```

### Les CRDs ESO ne sont pas creees

**Cause probable** : `installCRDs: true` n'est pas dans les values Helm.
```bash
kubectl get crd | grep external-secrets
# Doit afficher : externalsecrets.external-secrets.io, secretstores.external-secrets.io, etc.
```

### Les pods ESO sont en CrashLoopBackOff

**Cause probable** : le webhook n'arrive pas a demarrer (certificats).
```bash
kubectl logs -l app.kubernetes.io/name=external-secrets-cert-controller -n external-secrets
```

## Nettoyage

```bash
# Supprimer le ClusterSecretStore
kubectl delete clustersecretstore vault-backend

# Supprimer le secret du token
kubectl delete secret vault-token -n external-secrets

# Supprimer l'Application ArgoCD
kubectl delete application external-secrets -n argocd

# Supprimer le namespace
kubectl delete ns external-secrets
```

## Pour aller plus loin

- [Documentation ESO](https://external-secrets.io/)
- [ESO Vault Provider](https://external-secrets.io/latest/provider/hashicorp-vault/)
- [Kubernetes Auth Method pour Vault](https://developer.hashicorp.com/vault/docs/auth/kubernetes) (recommande en production)
- Migrer de l'auth par token vers l'auth Kubernetes pour eliminer le secret statique

## QCM de revision

**Question 1** : Quelle est la difference entre un SecretStore et un ClusterSecretStore ?

- A) SecretStore est pour les secrets simples, ClusterSecretStore pour les secrets complexes
- B) SecretStore est limite a un namespace, ClusterSecretStore est accessible depuis tous les namespaces
- C) SecretStore utilise HTTP, ClusterSecretStore utilise HTTPS
- D) Il n'y a pas de difference, ce sont des alias

<details>
<summary>Reponse</summary>
<b>B)</b> Un <code>SecretStore</code> est namespace-scoped : seuls les <code>ExternalSecrets</code> du meme namespace peuvent l'utiliser. Un <code>ClusterSecretStore</code> est cluster-wide : les <code>ExternalSecrets</code> de n'importe quel namespace peuvent le referencer.
</details>

---

**Question 2** : Pourquoi utilise-t-on l'authentification par token plutot que l'auth Kubernetes dans ce TP ?

- A) Parce que l'auth par token est plus securisee
- B) Parce que l'auth Kubernetes n'est pas supportee par ESO
- C) Par simplicite pedagogique -- l'auth Kubernetes necessite une configuration supplementaire dans Vault
- D) Parce que le token est automatiquement renouvele

<details>
<summary>Reponse</summary>
<b>C)</b> L'auth Kubernetes (recommandee en production) necessite de configurer un auth backend dans Vault, creer un role, lier un ServiceAccount, etc. Pour un TP, l'auth par token est plus simple a mettre en place. En production, le root token ne devrait JAMAIS etre utilise pour l'acces applicatif.
</details>

---

**Question 3** : Quel est le role du Secret Kubernetes `vault-token` dans le namespace `external-secrets` ?

- A) Il contient les cles TLS pour la connexion a Vault
- B) Il contient le token d'authentification que ESO utilise pour se connecter a Vault
- C) Il contient les credentials de la base de donnees
- D) Il est genere automatiquement par Vault

<details>
<summary>Reponse</summary>
<b>B)</b> Le Secret <code>vault-token</code> contient le token Vault (ici le root token) que ESO utilise pour s'authentifier aupres de Vault et lire les secrets. Le <code>ClusterSecretStore</code> reference ce secret via <code>tokenSecretRef</code>.
</details>

---

**Question 4** : Que signifie `path: "secret"` et `version: "v2"` dans le ClusterSecretStore ?

- A) Le chemin du fichier de configuration et la version d'ESO
- B) Le path du moteur de secrets KV dans Vault et la version du moteur KV (v2 supporte le versioning)
- C) Le chemin de l'API Kubernetes et la version de l'API
- D) Le nom du namespace et la version du chart Helm

<details>
<summary>Reponse</summary>
<b>B)</b> <code>path: "secret"</code> correspond au path ou le moteur KV est monte dans Vault (<code>vault secrets enable -path=secret kv-v2</code>). <code>version: "v2"</code> indique que c'est un moteur KV version 2, qui supporte le versioning des secrets (historique des modifications).
</details>

---

**Question 5** : Que se passe-t-il si le ClusterSecretStore est en etat "Invalid" ?

- A) Les ExternalSecrets continuent de fonctionner avec les anciennes valeurs
- B) Les ExternalSecrets ne peuvent pas synchroniser de nouveaux secrets et affichent une erreur
- C) Kubernetes supprime automatiquement les Secrets associes
- D) ESO redemarrre automatiquement pour corriger le probleme

<details>
<summary>Reponse</summary>
<b>B)</b> Si le ClusterSecretStore est "Invalid", les ExternalSecrets qui le referencent ne peuvent pas synchroniser les secrets depuis Vault. Les Secrets Kubernetes existants restent en place mais ne sont plus mis a jour. Les nouveaux ExternalSecrets afficheront une erreur de synchronisation.
</details>
