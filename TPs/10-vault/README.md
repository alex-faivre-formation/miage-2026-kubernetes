# TP10 - HashiCorp Vault -- Gestion des secrets

## Introduction theorique

Ce TP couvre le deploiement de **HashiCorp Vault** dans Kubernetes pour la gestion securisee des secrets. Vault est un outil de gestion de secrets centralise qui va bien au-dela des Secrets Kubernetes natifs en offrant le chiffrement, la rotation automatique, l'audit et la generation dynamique de credentials.

### Le probleme des secrets dans Kubernetes

Les Secrets Kubernetes natifs ont des limitations importantes :

```
  Secret Kubernetes natif
  =======================

  apiVersion: v1
  kind: Secret
  data:
    password: czNjcjN0    <-- Base64, PAS du chiffrement !
                               echo "czNjcjN0" | base64 -d  -->  "s3cr3t"
```

**Limites des Secrets Kubernetes :**
- **Encodage Base64 != chiffrement** : n'importe qui avec acces au namespace peut decoder les secrets
- **Pas de rotation automatique** : les secrets doivent etre mis a jour manuellement
- **Pas d'audit trail** : impossible de savoir qui a lu quel secret et quand
- **Pas de generation dynamique** : impossible de generer des credentials a duree de vie limitee
- **Stockage dans etcd** : par defaut, les secrets sont stockes en clair dans etcd (le chiffrement au repos est optionnel et doit etre configure explicitement)

### Qu'est-ce que HashiCorp Vault ?

Vault est un systeme centralise de gestion de secrets qui offre :

```
+------------------------------------------------------------------+
|                        HashiCorp Vault                            |
|                                                                   |
|  +------------------+  +------------------+  +-----------------+  |
|  | Secrets Engines  |  | Auth Methods     |  | Policies        |  |
|  |                  |  |                  |  |                 |  |
|  | - KV (cle/val)   |  | - Token          |  | - path "secret" |  |
|  | - Database       |  | - Kubernetes     |  |   read, list   |  |
|  | - PKI (certifs)  |  | - LDAP           |  | - path "db"    |  |
|  | - AWS            |  | - AppRole        |  |   create       |  |
|  | - SSH            |  | - OIDC           |  |                 |  |
|  +------------------+  +------------------+  +-----------------+  |
|                                                                   |
|  +------------------------------------------------------------+  |
|  | Storage Backend                                             |  |
|  | - Raft (integre, HA)    - Consul    - etcd                  |  |
|  +------------------------------------------------------------+  |
|                                                                   |
|  +------------------------------------------------------------+  |
|  | Audit Devices                                               |  |
|  | - File    - Syslog    - Socket                              |  |
|  +------------------------------------------------------------+  |
+------------------------------------------------------------------+
```

### L'algorithme de Shamir (Shamir's Secret Sharing)

L'algorithme de Shamir (1979, par Adi Shamir, le "S" de RSA) est un algorithme cryptographique qui divise un secret en N fragments dont K suffisent pour le reconstruire. Il est base sur l'interpolation polynomiale :

```
  Cle maitre Vault (master key)
  =============================

  La cle est un point sur un polynome de degre (K-1)

  Avec key-shares=5, key-threshold=3 :

      ^
      |         *  (fragment 5 - Responsable E)
      |     *      (fragment 4 - Responsable D)
      |   *        (fragment 3 - Responsable C)
      |  *         (fragment 2 - Responsable B)
      | *          (fragment 1 - Responsable A)
      +--*----------------------------------->
         ^
         |
    Cle maitre (intersection avec l'axe Y)

  3 fragments parmi 5 suffisent pour reconstruire le polynome
  et retrouver la cle maitre (interpolation de Lagrange)
```

**Proprietes importantes :**
- Avec moins de K fragments, il est **mathematiquement impossible** de retrouver le secret
- Chaque fragment seul ne revele **aucune information** sur le secret
- C'est la base de la **separation des privileges** : aucun individu seul ne peut acceder aux secrets

### Le processus Seal/Unseal

Vault utilise un mecanisme de **scellement** (seal) pour proteger les donnees :

```
  Demarrage de Vault
  ==================

  1. Vault demarre  -->  Etat: SEALED (scelle)
     Les donnees sont chiffrees, rien n'est accessible

  2. Ceremonie d'unseal (descellement)
     Responsable A fournit son fragment  --> Progress: 1/3
     Responsable B fournit son fragment  --> Progress: 2/3
     Responsable C fournit son fragment  --> Progress: 3/3

  3. Cle maitre reconstruite  -->  Etat: UNSEALED
     Vault dechiffre la cle de chiffrement des donnees
     Les secrets sont accessibles

  Architecture de chiffrement :
  +------------------+
  | Cle maitre       | (reconstruite via Shamir)
  | (master key)     |
  +--------+---------+
           | dechiffre
           v
  +------------------+
  | Cle de           | (stockee chiffree dans le backend)
  | chiffrement      |
  | (encryption key) |
  +--------+---------+
           | chiffre/dechiffre
           v
  +------------------+
  | Donnees Vault    |
  | (secrets, config,|
  |  policies, etc.) |
  +------------------+
```

### Le protocole Raft pour la haute disponibilite

Raft est un protocole de consensus distribue utilise par Vault pour la haute disponibilite. Il garantit que les donnees sont repliquees sur tous les noeuds du cluster :

```
  Cluster Vault HA avec Raft
  ==========================

  +-------------------+
  | vault-0 (LEADER)  |  <-- Recoit les ecritures
  | Raft: leader      |      et les replique
  +--------+----------+
           |  replication
     +-----+-----+
     v            v
  +----------+ +----------+
  | vault-1  | | vault-2  |
  | follower | | follower |
  +----------+ +----------+

  - Ecriture : envoyee au leader, repliquee aux followers
  - Lecture : possible depuis n'importe quel noeud
  - Election : si le leader tombe, les followers elisent un nouveau leader
  - Quorum : majorite necessaire (2/3) pour accepter une ecriture
```

### Vault vs Secrets Kubernetes natifs

| Critere | Secrets K8s | Vault |
|---------|-------------|-------|
| Chiffrement au repos | Optionnel (config etcd) | Natif, toujours actif |
| Encodage | Base64 (pas du chiffrement) | AES-256-GCM |
| Rotation automatique | Non | Oui (dynamic secrets, leases) |
| Audit trail | Limite (audit K8s API) | Complet et dedie (qui, quoi, quand) |
| Generation dynamique | Non | Oui (DB, PKI, AWS, SSH) |
| Controle d'acces | RBAC K8s (namespace) | Policies granulaires (par chemin) |
| Multi-cluster | Non | Oui (Vault centralise) |
| Duree de vie des secrets | Infinie | Configurable (leases, TTL) |
| Revocation | Manuelle | Automatique (expiration) ou manuelle |

## Objectifs

- Deployer Vault en mode HA avec Raft dans Kubernetes
- Comprendre l'algorithme de Shamir et la ceremonie des cles
- Initialiser et desceller Vault
- Acceder a l'interface web de Vault
- Comparer Vault aux Secrets Kubernetes natifs

## Prerequis

- Un cluster Kubernetes fonctionnel (minikube, Docker Desktop, etc.)
- `kubectl` installe et configure
- `helm` installe (v3+)
- `jq` installe (pour parser le JSON)

## Architecture deployee

```
Cluster Kubernetes
+-------------------------------------------------------------------+
|                                                                   |
|  Namespace: vault                                                 |
|  +-------------------------------------------------------------+ |
|  |                                                             | |
|  |  StatefulSet vault (3 replicas)                             | |
|  |  +---------------+  +---------------+  +---------------+   | |
|  |  | vault-0       |  | vault-1       |  | vault-2       |   | |
|  |  | LEADER        |  | FOLLOWER      |  | FOLLOWER      |   | |
|  |  | port: 8200    |  | port: 8200    |  | port: 8200    |   | |
|  |  | (API + UI)    |  | (API + UI)    |  | (API + UI)    |   | |
|  |  | port: 8201    |  | port: 8201    |  | port: 8201    |   | |
|  |  | (cluster)     |  | (cluster)     |  | (cluster)     |   | |
|  |  +-------+-------+  +-------+-------+  +-------+-------+   | |
|  |          |                   |                   |           | |
|  |          +------- Raft replication --------------+           | |
|  |                                                             | |
|  |  +------------------+  +----------------------------------+ | |
|  |  | Service vault    |  | Service vault-internal           | | |
|  |  | (API externe)    |  | (communication inter-noeuds)     | | |
|  |  | port: 8200       |  | port: 8200, 8201                | | |
|  |  +------------------+  +----------------------------------+ | |
|  |                                                             | |
|  |  +------------------+  +------------------+                 | |
|  |  | PVC vault-0      |  | PVC vault-1      |  ...           | |
|  |  | 10Gi (data)      |  | 10Gi (data)      |                | |
|  |  +------------------+  +------------------+                 | |
|  +-------------------------------------------------------------+ |
+-------------------------------------------------------------------+
```

## Fichiers et explication detaillee

### `helm-vault-raft-values.yml` -- Configuration simple (dev/lab)

```yaml
server:
  affinity: ""                     # Desactive l'anti-affinite (permet plusieurs pods sur le meme noeud)
  ha:
    enabled: true                  # Active le mode haute disponibilite
    raft:
      enabled: true                # Utilise Raft comme backend de stockage
      setNodeId: true              # Attribue automatiquement un ID a chaque noeud
      config: |
        ui = true                  # Active l'interface web
        cluster_name = "vault-integrated-storage"
        storage "raft" {
          path = "/vault/data/"    # Repertoire de stockage des donnees Raft
        }
        listener "tcp" {
          address = "[::]:8200"           # Port API (ecoute sur toutes les interfaces)
          cluster_address = "[::]:8201"   # Port communication inter-noeuds
          tls_disable = "true"            # Desactive TLS (dev uniquement !)
        }
        service_registration "kubernetes" {}   # Enregistre Vault dans K8s pour le service discovery
```

**Champs importants :**
- `affinity: ""` : par defaut, le chart Helm Vault configure une anti-affinite pour empecher deux pods Vault d'etre sur le meme noeud. On la desactive ici car en dev on a souvent un seul noeud.
- `ha.enabled: true` : active le mode HA. Vault deploiera 3 replicas par defaut (StatefulSet).
- `raft.enabled: true` : utilise le protocole Raft integre comme backend de stockage. Alternative a Consul ou etcd.
- `tls_disable = "true"` : desactive le TLS entre les clients et Vault. **A ne jamais faire en production** -- le trafic contient des secrets en clair.
- `service_registration "kubernetes"` : Vault s'enregistre aupres de Kubernetes pour que les Services puissent router le trafic vers le leader actif.

### `helm-vault-ha-values.yml` -- Configuration HA complete (production)

```yaml
server:
  ha:
    enabled: true
    replicas: 3                    # 3 replicas explicitement
    raft:
      enabled: true
      setNodeId: true
      config: |
        ui = true
        listener "tcp" {
          tls_disable = 1
          address = "[::]:8200"
          cluster_address = "[::]:8201"
        }
        storage "raft" {
          path = "/vault/data"
          retry_join {                                              # Auto-join au cluster
            leader_api_addr = "http://vault-0.vault-internal:8200"  # vault-0 comme leader potentiel
          }
          retry_join {
            leader_api_addr = "http://vault-1.vault-internal:8200"  # vault-1 comme leader potentiel
          }
          retry_join {
            leader_api_addr = "http://vault-2.vault-internal:8200"  # vault-2 comme leader potentiel
          }
        }
        service_registration "kubernetes" {}
  dataStorage:
    enabled: true
    size: 10Gi                     # 10 Go de stockage pour les donnees Raft
    storageClass: "standard"       # Classe de stockage (adapter a votre cluster)
  auditStorage:
    enabled: true
    size: 5Gi                      # 5 Go pour les logs d'audit
    storageClass: "standard"
  serviceAccount:
    create: true                   # Cree un ServiceAccount dedie pour Vault
  ingress:
    enabled: true
    className: "nginx"             # Utilise l'Ingress Controller NGINX (TP09)
    hosts:
      - host: vault.example.com   # Hostname d'acces a l'interface Vault
```

**Champs importants :**
- `retry_join` : chaque noeud tente automatiquement de rejoindre le cluster Raft en contactant les autres noeuds. Le DNS `vault-X.vault-internal` est fourni par le Service headless `vault-internal` du StatefulSet.
- `dataStorage` : configure un PersistentVolumeClaim de 10Gi pour chaque replica. Les donnees Raft (secrets chiffres, configuration) sont stockees ici.
- `auditStorage` : stockage dedie pour les logs d'audit. En production, ces logs sont essentiels pour la conformite (qui a accede a quel secret, quand).
- `ingress` : expose Vault via un Ingress NGINX (necessite le TP09). En dev, on utilise `port-forward` a la place.

### `setup.sh` -- Script d'installation et d'initialisation

```bash
#!/bin/bash
# Script d'installation et d'initialisation de Vault

# Creation du namespace
kubectl create ns vault

# Config Helm
helm repo add hashicorp https://helm.releases.hashicorp.com
helm repo update
helm search repo hashicorp/vault

# Installation de Vault
helm install vault hashicorp/vault \
  --values helm-vault-raft-values.yml \
  --create-namespace \
  --namespace vault

# Attendre que les pods soient prets
echo "Attente du demarrage des pods Vault..."
sleep 30

# Initialisation de Vault (1 cle, seuil 1 -- dev uniquement)
kubectl exec vault-0 -n vault -- vault operator init \
  -key-shares=1 \
  -key-threshold=1 \
  -format=json > cluster-keys.json

# Recuperation de la cle de descellement
jq -r ".unseal_keys_b64[]" cluster-keys.json
VAULT_UNSEAL_KEY=$(jq -r ".unseal_keys_b64[]" cluster-keys.json)

# Descellement du premier noeud
kubectl exec vault-0 -n vault -- vault operator unseal $VAULT_UNSEAL_KEY

# Jonction des noeuds au cluster Raft
kubectl exec -ti vault-1 -n vault -- vault operator raft join http://vault-0.vault-internal:8200
kubectl exec -ti vault-2 -n vault -- vault operator raft join http://vault-0.vault-internal:8200

# Descellement des noeuds secondaires
kubectl exec -ti vault-1 -n vault -- vault operator unseal $VAULT_UNSEAL_KEY
kubectl exec -ti vault-2 -n vault -- vault operator unseal $VAULT_UNSEAL_KEY

# Affichage du token root
echo "Root token:"
jq -r ".root_token" cluster-keys.json

echo "Pour acceder a l'interface Vault:"
echo "kubectl port-forward svc/vault 8200:8200 -n vault"
```

**Explication du script :**
- Le script utilise `key-shares=1` et `key-threshold=1` pour simplifier (une seule cle suffit pour desceller). **En production, utilisez au minimum 5 shares et un threshold de 3**.
- L'initialisation (`vault operator init`) ne se fait qu'une seule fois, a la premiere installation. Elle genere les cles de descellement et le token root.
- Le `raft join` fait rejoindre vault-1 et vault-2 au cluster Raft dont vault-0 est le leader initial.
- Chaque noeud doit etre descelle individuellement -- le descellement n'est pas propage automatiquement.

## Deploiement pas a pas

### 1. Preparer Helm

```bash
kubectl create ns vault
helm repo add hashicorp https://helm.releases.hashicorp.com
helm repo update
```

Sortie attendue :
```
namespace/vault created
"hashicorp" has been added to your repositories
Hang tight while we grab the latest from your chart repositories...
Update Complete. Happy Helming!
```

### 2. Installer Vault

```bash
# Configuration simple (dev/lab)
helm install vault hashicorp/vault \
  --values helm-vault-raft-values.yml \
  --namespace vault
```

Sortie attendue :
```
NAME: vault
LAST DEPLOYED: ...
NAMESPACE: vault
STATUS: deployed
```

### 3. Verifier les pods

```bash
kubectl get pods -n vault
```

Sortie attendue :
```
NAME                                    READY   STATUS    RESTARTS   AGE
vault-0                                 0/1     Running   0          30s
vault-1                                 0/1     Running   0          30s
vault-2                                 0/1     Running   0          30s
vault-agent-injector-xxxxxxxxx-xxxxx    1/1     Running   0          30s
```

Les pods sont `Running` mais `0/1 Ready` : c'est **normal**. Vault est en etat **sealed** (scelle). Il ne deviendra Ready qu'apres le descellement.

### 4. Initialiser Vault (premiere fois uniquement)

```bash
kubectl exec vault-0 -n vault -- vault operator init \
  -key-shares=5 \
  -key-threshold=3 \
  -format=json > cluster-keys.json
```

Cette commande genere :
- **5 cles de descellement** (unseal keys) au format Base64
- **1 token root** (a conserver precieusement)

```bash
# Afficher les cles
cat cluster-keys.json | jq
```

Sortie attendue :
```json
{
  "unseal_keys_b64": [
    "aB1cD2eF3gH4iJ5kL6mN7oP8qR9sT0u...",
    "bC2dE3fG4hI5jK6lM7nO8pQ9rS0tU1v...",
    "cD3eF4gH5iJ6kL7mN8oP9qR0sT1uV2w...",
    "dE4fG5hI6jK7lM8nO9pQ0rS1tU2vW3x...",
    "eF5gH6iJ7kL8mN9oP0qR1sT2uV3wX4y..."
  ],
  "unseal_keys_hex": [...],
  "root_token": "hvs.XXXXXXXXXXXXXXXXXXXX"
}
```

**IMPORTANT** : sauvegardez `cluster-keys.json` en lieu sur. En production, distribuez les cles a des personnes differentes.

### 5. Desceller vault-0

```bash
VAULT_UNSEAL_KEY_1=$(jq -r ".unseal_keys_b64[0]" cluster-keys.json)
VAULT_UNSEAL_KEY_2=$(jq -r ".unseal_keys_b64[1]" cluster-keys.json)
VAULT_UNSEAL_KEY_3=$(jq -r ".unseal_keys_b64[2]" cluster-keys.json)

kubectl exec vault-0 -n vault -- vault operator unseal $VAULT_UNSEAL_KEY_1
kubectl exec vault-0 -n vault -- vault operator unseal $VAULT_UNSEAL_KEY_2
kubectl exec vault-0 -n vault -- vault operator unseal $VAULT_UNSEAL_KEY_3
```

Sortie attendue (apres la 3eme cle) :
```
Key                     Value
---                     -----
Seal Type               shamir
Initialized             true
Sealed                  false       <-- Vault est descelle !
Total Shares            5
Threshold               3
Version                 1.x.x
Storage Type            raft
Cluster Name            vault-integrated-storage
Cluster ID              xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
HA Enabled              true
HA Cluster              https://vault-0.vault-internal:8201
HA Mode                 active
Active Since            2024-xx-xxTxx:xx:xxZ
Raft Committed Index    xx
Raft Applied Index      xx
```

### 6. Joindre et desceller vault-1 et vault-2

```bash
# Joindre au cluster Raft
kubectl exec -ti vault-1 -n vault -- vault operator raft join http://vault-0.vault-internal:8200
kubectl exec -ti vault-2 -n vault -- vault operator raft join http://vault-0.vault-internal:8200
```

Sortie attendue :
```
Key       Value
---       -----
Joined    true
```

```bash
# Desceller vault-1
kubectl exec vault-1 -n vault -- vault operator unseal $VAULT_UNSEAL_KEY_1
kubectl exec vault-1 -n vault -- vault operator unseal $VAULT_UNSEAL_KEY_2
kubectl exec vault-1 -n vault -- vault operator unseal $VAULT_UNSEAL_KEY_3

# Desceller vault-2
kubectl exec vault-2 -n vault -- vault operator unseal $VAULT_UNSEAL_KEY_1
kubectl exec vault-2 -n vault -- vault operator unseal $VAULT_UNSEAL_KEY_2
kubectl exec vault-2 -n vault -- vault operator unseal $VAULT_UNSEAL_KEY_3
```

### 7. Verifier que tous les pods sont Ready

```bash
kubectl get pods -n vault
```

Sortie attendue :
```
NAME                                    READY   STATUS    RESTARTS   AGE
vault-0                                 1/1     Running   0          5m
vault-1                                 1/1     Running   0          5m
vault-2                                 1/1     Running   0          5m
vault-agent-injector-xxxxxxxxx-xxxxx    1/1     Running   0          5m
```

### 8. Acceder a l'interface web

```bash
kubectl port-forward svc/vault 8200:8200 -n vault
```

Ouvrir : **http://localhost:8200**

```bash
# Recuperer le token root
jq -r ".root_token" cluster-keys.json
```

Se connecter avec le token root.

## Exercice -- Stocker et lire un secret

### Activer le secrets engine KV

```bash
kubectl exec vault-0 -n vault -- vault login $(jq -r ".root_token" cluster-keys.json)

kubectl exec vault-0 -n vault -- vault secrets enable -path=secret kv-v2
```

### Ecrire un secret

```bash
kubectl exec vault-0 -n vault -- vault kv put secret/myapp/config \
  username="dbuser" \
  password="s3cr3t" \
  host="postgres.default.svc"
```

### Lire un secret

```bash
kubectl exec vault-0 -n vault -- vault kv get secret/myapp/config
```

Sortie attendue :
```
====== Data ======
Key         Value
---         -----
host        postgres.default.svc
password    s3cr3t
username    dbuser
```

## Commandes utiles

```bash
# Statut de Vault
kubectl exec vault-0 -n vault -- vault status

# Lister les membres du cluster Raft
kubectl exec vault-0 -n vault -- vault operator raft list-peers

# Lister les secrets engines actives
kubectl exec vault-0 -n vault -- vault secrets list

# Lister les auth methods actives
kubectl exec vault-0 -n vault -- vault auth list

# Voir les logs d'un noeud Vault
kubectl logs vault-0 -n vault

# Verifier quel noeud est le leader
kubectl exec vault-0 -n vault -- vault status | grep "HA Mode"
```

## Troubleshooting

### Les pods Vault restent en `0/1 Ready`

**Cause probable** : Vault est sealed (scelle). C'est le comportement normal avant l'initialisation et le descellement.
```bash
kubectl exec vault-0 -n vault -- vault status
# Sealed: true
```
**Solution** : suivre les etapes d'initialisation et de descellement ci-dessus.

### Erreur `vault operator init` : "Vault is already initialized"

**Cause probable** : Vault a deja ete initialise. L'initialisation ne se fait qu'une seule fois.
```bash
kubectl exec vault-0 -n vault -- vault status
# Initialized: true
```
**Solution** : passer directement a l'etape de descellement. Si vous avez perdu les cles, il faudra reinstaller Vault (suppression des PVC incluse).

### Erreur `raft join` : connection refused

**Cause probable** : vault-0 n'est pas encore descelle ou n'est pas pret.
```bash
kubectl exec vault-0 -n vault -- vault status
```
**Solution** : s'assurer que vault-0 est descelle (`Sealed: false`) avant de joindre les autres noeuds.

### Le port-forward ne fonctionne pas

**Cause probable** : le service Vault n'a pas d'endpoints (aucun pod Ready).
```bash
kubectl get endpoints vault -n vault
```
**Solution** : desceller au moins un noeud Vault pour qu'il devienne Ready.

### Vault se re-scelle apres un redemarrage de pod

**Cause normale** : Vault se scelle automatiquement a chaque redemarrage. C'est une mesure de securite.
```bash
# Re-desceller apres un restart
kubectl exec vault-0 -n vault -- vault operator unseal $VAULT_UNSEAL_KEY_1
kubectl exec vault-0 -n vault -- vault operator unseal $VAULT_UNSEAL_KEY_2
kubectl exec vault-0 -n vault -- vault operator unseal $VAULT_UNSEAL_KEY_3
```
**Note** : en production, on utilise l'**auto-unseal** avec un KMS cloud (AWS KMS, GCP KMS, Azure Key Vault) pour eviter cette etape manuelle.

### Erreur de stockage : "no raft cluster configuration found"

**Cause probable** : les PVC ont ete supprimes mais pas les pods, ou le cluster Raft est corrompu.
```bash
kubectl get pvc -n vault
```
**Solution** : desinstaller completement Vault, supprimer les PVC et reinstaller :
```bash
helm uninstall vault -n vault
kubectl delete pvc -l app.kubernetes.io/name=vault -n vault
```

## Nettoyage

```bash
# Desinstaller Vault
helm uninstall vault -n vault

# Supprimer les PVC (donnees Raft)
kubectl delete pvc -l app.kubernetes.io/name=vault -n vault

# Supprimer le namespace
kubectl delete namespace vault

# Supprimer le fichier de cles local
rm -f cluster-keys.json
```

> **Attention** : la suppression de Vault detruit toutes les donnees et secrets stockes. En production, effectuez un snapshot Raft avant la suppression :
> ```bash
> kubectl exec vault-0 -n vault -- vault operator raft snapshot save /tmp/raft-snapshot.snap
> kubectl cp vault-0:/tmp/raft-snapshot.snap ./raft-backup.snap -n vault
> ```

## Pour aller plus loin

- [Documentation officielle Vault](https://developer.hashicorp.com/vault/docs)
- [Vault sur Kubernetes](https://developer.hashicorp.com/vault/docs/platform/k8s)
- [Vault Agent Injector](https://developer.hashicorp.com/vault/docs/platform/k8s/injector) pour injecter automatiquement les secrets dans les Pods
- [Dynamic Secrets](https://developer.hashicorp.com/vault/docs/secrets/databases) pour generer des credentials de base de donnees a duree de vie limitee
- [Auto-Unseal](https://developer.hashicorp.com/vault/docs/concepts/seal#auto-unseal) avec AWS KMS, GCP KMS ou Azure Key Vault
- [External Secrets Operator](https://external-secrets.io/) pour synchroniser les secrets Vault avec des Secrets Kubernetes

**Suggestions d'amelioration :**
- Configurer l'auth method Kubernetes pour que les Pods puissent s'authentifier automatiquement aupres de Vault
- Utiliser le Vault Agent Injector pour injecter les secrets comme fichiers dans les Pods (annotations)
- Configurer des dynamic secrets pour PostgreSQL (generation automatique de credentials avec TTL)
- Mettre en place l'auto-unseal avec un KMS cloud pour eviter la ceremonie manuelle
- Activer l'audit logging et exporter les logs vers un SIEM
- Explorer le CSI Provider Vault pour monter les secrets comme volumes

## QCM de revision

**Question 1** : Pourquoi les Secrets Kubernetes natifs ne sont-ils pas suffisants pour la gestion de secrets en production ?

- A) Ils ne supportent pas le format JSON
- B) Ils sont encodes en Base64 (pas chiffres), sans rotation automatique ni audit trail
- C) Ils ne peuvent stocker que des mots de passe
- D) Ils sont limites a 1 Ko de donnees

<details>
<summary>Reponse</summary>
<b>B)</b> Les Secrets Kubernetes utilisent un simple encodage Base64 qui n'est pas du chiffrement (<code>echo "czNjcjN0" | base64 -d</code> revele immediatement le secret). De plus, ils n'offrent pas de rotation automatique, pas d'audit trail detaille, et pas de generation dynamique de credentials.
</details>

---

**Question 2** : Avec `key-shares=5` et `key-threshold=3`, combien de personnes doivent participer au descellement de Vault ?

- A) 1
- B) 3
- C) 5
- D) 8 (5+3)

<details>
<summary>Reponse</summary>
<b>B)</b> Le <code>key-threshold</code> definit le nombre minimum de fragments necessaires pour reconstruire la cle maitre. Avec un threshold de 3, il faut que 3 personnes (parmi les 5 detentrices de fragments) fournissent leur cle pour desceller Vault.
</details>

---

**Question 3** : Pourquoi les pods Vault sont-ils en `0/1 Ready` apres l'installation ?

- A) L'installation a echoue
- B) Il manque des ressources CPU/memoire
- C) Vault est en etat sealed (scelle) et n'a pas encore ete initialise/descelle
- D) Les PersistentVolumeClaims ne sont pas lies

<details>
<summary>Reponse</summary>
<b>C)</b> C'est le comportement normal de Vault. Apres le demarrage, Vault est en etat <code>sealed</code> : il refuse toute requete et signale qu'il n'est pas pret (0/1 Ready). Il faut l'initialiser puis le desceller pour qu'il devienne Ready (1/1).
</details>

---

**Question 4** : Quel protocole Vault utilise-t-il pour la replication des donnees entre les noeuds en mode HA ?

- A) Paxos
- B) Raft
- C) Gossip
- D) 2PC (Two-Phase Commit)

<details>
<summary>Reponse</summary>
<b>B)</b> Vault utilise le protocole de consensus <b>Raft</b> (integre) pour la replication des donnees entre les noeuds. Raft garantit la coherence des donnees en exigeant qu'une majorite de noeuds (quorum) approuve chaque ecriture. Un noeud est elu leader et les autres sont des followers.
</details>

---

**Question 5** : Que se passe-t-il si un pod Vault redemarre (ex: apres un crash ou un rolling update) ?

- A) Vault redemarre automatiquement en etat unsealed
- B) Vault redemarre en etat sealed et doit etre descelle a nouveau
- C) Le pod ne redemarrera pas sans intervention manuelle
- D) Les secrets sont perdus

<details>
<summary>Reponse</summary>
<b>B)</b> Vault se scelle automatiquement a chaque redemarrage. C'est une mesure de securite : la cle maitre n'est jamais stockee sur disque. Chaque redemarrage necessite une nouvelle ceremonie de descellement. En production, on utilise l'<b>auto-unseal</b> avec un KMS cloud pour automatiser ce processus.
</details>

---

**Question 6** : Quelle est la difference entre le token root et les cles de descellement ?

- A) Ce sont la meme chose
- B) Les cles de descellement servent a desceller Vault, le token root sert a s'authentifier pour acceder aux secrets
- C) Le token root est plus securise que les cles de descellement
- D) Les cles de descellement sont pour la lecture, le token root pour l'ecriture

<details>
<summary>Reponse</summary>
<b>B)</b> Les cles de descellement (unseal keys) servent a reconstruire la cle maitre via l'algorithme de Shamir pour desceller Vault. Le token root est un jeton d'authentification avec tous les privileges, utilise pour configurer Vault (policies, auth methods, secrets engines). En production, le token root doit etre revoque apres la configuration initiale.
</details>

---

**Question 7** : Pourquoi `tls_disable = "true"` est-il dangereux en production ?

- A) Cela desactive le chiffrement des donnees au repos
- B) Cela desactive le chiffrement TLS entre les clients et Vault, exposant les secrets en clair sur le reseau
- C) Cela empeche Vault de demarrer correctement
- D) Cela desactive l'authentification

<details>
<summary>Reponse</summary>
<b>B)</b> Sans TLS, toute communication entre un client et Vault se fait en clair sur le reseau. Les secrets, tokens et cles d'authentification peuvent etre interceptes par un attaquant (attaque man-in-the-middle). En production, TLS doit toujours etre active avec des certificats valides.
</details>

---

**Question 8** : Qu'est-ce qu'un "dynamic secret" dans Vault ?

- A) Un secret qui change de nom aleatoirement
- B) Un credential genere a la demande avec une duree de vie limitee (TTL), automatiquement revoque a expiration
- C) Un secret stocke dans un format dynamique (JSON, YAML, etc.)
- D) Un secret qui est chiffre avec une cle differente a chaque lecture

<details>
<summary>Reponse</summary>
<b>B)</b> Les dynamic secrets sont des credentials generes a la volee par Vault. Par exemple, Vault peut creer un utilisateur PostgreSQL avec un mot de passe unique et un TTL de 1 heure. A expiration, Vault revoque automatiquement le credential. Cela elimine le probleme des secrets permanents et partages.
</details>
