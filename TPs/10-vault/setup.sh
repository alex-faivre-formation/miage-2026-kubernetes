#!/bin/bash
# Script d'installation et d'initialisation de Vault

# Création du namespace
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

# Attendre que les pods soient prêts
echo "Attente du démarrage des pods Vault..."
sleep 30

# Initialisation de Vault
kubectl exec vault-0 -n vault -- vault operator init \
  -key-shares=1 \
  -key-threshold=1 \
  -format=json > cluster-keys.json

# Récupération de la clé de déscellement
jq -r ".unseal_keys_b64[]" cluster-keys.json
VAULT_UNSEAL_KEY=$(jq -r ".unseal_keys_b64[]" cluster-keys.json)

# Déscellement du premier noeud
kubectl exec vault-0 -n vault -- vault operator unseal $VAULT_UNSEAL_KEY

# Jonction des noeuds au cluster Raft
kubectl exec -ti vault-1 -n vault -- vault operator raft join http://vault-0.vault-internal:8200
kubectl exec -ti vault-2 -n vault -- vault operator raft join http://vault-0.vault-internal:8200

# Déscellement des noeuds secondaires
kubectl exec -ti vault-1 -n vault -- vault operator unseal $VAULT_UNSEAL_KEY
kubectl exec -ti vault-2 -n vault -- vault operator unseal $VAULT_UNSEAL_KEY

# Affichage du token root
echo "Root token:"
jq -r ".root_token" cluster-keys.json

echo "Pour accéder à l'interface Vault:"
echo "kubectl port-forward svc/vault 8200:8200 -n vault"
