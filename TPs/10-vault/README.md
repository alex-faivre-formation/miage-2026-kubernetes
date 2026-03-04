# TP10 - HashiCorp Vault — Gestion des secrets

## Objectifs
- Déployer Vault en mode HA avec Raft dans Kubernetes
- Comprendre l'algorithme de Shamir et la cérémonie des clés
- Initialiser et desceller Vault
- Comparer Vault aux Secrets Kubernetes natifs

## Prérequis
- Cluster Kubernetes fonctionnel
- `helm` installé
- `jq` installé (pour parser le JSON)

## Fichiers

| Fichier | Description |
|---------|-------------|
| `helm-vault-raft-values.yml` | Values Helm pour Vault en mode HA/Raft (configuration simple, 1 clé) |
| `helm-vault-ha-values.yml` | Values Helm pour Vault HA complet (3 replicas, storage, ingress) |
| `setup.sh` | Script complet d'installation et d'initialisation |

## Installation

### Via le script
```bash
chmod +x setup.sh
./setup.sh
```

### Manuellement

#### 1. Préparer Helm
```bash
kubectl create ns vault
helm repo add hashicorp https://helm.releases.hashicorp.com
helm repo update
```

#### 2. Installer Vault
```bash
# Configuration simple (dev/lab)
helm install vault hashicorp/vault \
  --values helm-vault-raft-values.yml \
  --create-namespace --namespace vault

# OU configuration HA complète (production)
helm install vault hashicorp/vault \
  --values helm-vault-ha-values.yml \
  --create-namespace --namespace vault
```

#### 3. Vérifier les pods
```bash
kubectl get pods -n vault
# vault-0   0/1   Running   (sealed)
# vault-1   0/1   Running   (sealed)
# vault-2   0/1   Running   (sealed)
```

Les pods sont `Running` mais `0/1 Ready` car Vault est **sealed** (scellé).

## Initialisation et descellement

### Initialiser Vault (première fois uniquement)
```bash
kubectl exec vault-0 -n vault -- vault operator init \
  -key-shares=5 \
  -key-threshold=3 \
  -format=json > cluster-keys.json
```

- `-key-shares=5` : la clé maître est divisée en 5 fragments
- `-key-threshold=3` : 3 fragments suffisent pour reconstruire la clé

### Desceller les noeuds
```bash
# Récupérer les clés
VAULT_UNSEAL_KEY_1=$(jq -r ".unseal_keys_b64[0]" cluster-keys.json)
VAULT_UNSEAL_KEY_2=$(jq -r ".unseal_keys_b64[1]" cluster-keys.json)
VAULT_UNSEAL_KEY_3=$(jq -r ".unseal_keys_b64[2]" cluster-keys.json)

# Desceller vault-0 (3 clés nécessaires)
kubectl exec vault-0 -n vault -- vault operator unseal $VAULT_UNSEAL_KEY_1
kubectl exec vault-0 -n vault -- vault operator unseal $VAULT_UNSEAL_KEY_2
kubectl exec vault-0 -n vault -- vault operator unseal $VAULT_UNSEAL_KEY_3

# Joindre et desceller vault-1 et vault-2
kubectl exec -ti vault-1 -n vault -- vault operator raft join http://vault-0.vault-internal:8200
kubectl exec -ti vault-2 -n vault -- vault operator raft join http://vault-0.vault-internal:8200

kubectl exec vault-1 -n vault -- vault operator unseal $VAULT_UNSEAL_KEY_1
kubectl exec vault-1 -n vault -- vault operator unseal $VAULT_UNSEAL_KEY_2
kubectl exec vault-1 -n vault -- vault operator unseal $VAULT_UNSEAL_KEY_3

kubectl exec vault-2 -n vault -- vault operator unseal $VAULT_UNSEAL_KEY_1
kubectl exec vault-2 -n vault -- vault operator unseal $VAULT_UNSEAL_KEY_2
kubectl exec vault-2 -n vault -- vault operator unseal $VAULT_UNSEAL_KEY_3
```

### Accéder à l'interface
```bash
kubectl port-forward svc/vault 8200:8200 -n vault
# Ouvrir http://localhost:8200

# Token root
jq -r ".root_token" cluster-keys.json
```

## L'algorithme de Shamir

L'algorithme de Shamir (1979) divise un secret en N fragments dont K suffisent pour le reconstruire :

```
Clé maître Vault
    │
    ├── Fragment 1 → Responsable A
    ├── Fragment 2 → Responsable B
    ├── Fragment 3 → Responsable C    ← 3 fragments suffisent
    ├── Fragment 4 → Responsable D       (key-threshold=3)
    └── Fragment 5 → Responsable E
```

Aucun individu seul ne peut accéder aux secrets (séparation des privilèges).

## Vault vs Secrets Kubernetes natifs

| Critère | Secrets K8s | Vault |
|---------|-------------|-------|
| Chiffrement au repos | Optionnel | Natif, toujours actif |
| Rotation automatique | Non | Oui (dynamic secrets) |
| Audit trail | Limité | Complet et dédié |
| Génération dynamique | Non | Oui (DB, PKI, AWS) |
| Multi-cluster | Non | Oui |

## Composants Vault

- **Secrets Engines** : KV, Database, PKI, AWS, SSH
- **Auth Methods** : Token, Kubernetes, LDAP, AppRole
- **Policies** : contrôle d'accès RBAC
- **Storage Backend** : Raft (intégré), Consul, etcd

## Nettoyage
```bash
helm uninstall vault -n vault
kubectl delete namespace vault
```

> **Attention** : la suppression de Vault détruit toutes les données et secrets stockés. Sauvegarder les snapshots Raft avant la suppression.
