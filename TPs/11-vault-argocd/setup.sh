#!/bin/bash
# TP11 - Deploiement de Vault via ArgoCD et initialisation
set -e

echo "=== TP11 : Vault via ArgoCD ==="

# Verifier qu'ArgoCD est installe
if ! kubectl get namespace argocd &>/dev/null; then
  echo "ERREUR : ArgoCD n'est pas installe. Suivez d'abord le TP08."
  exit 1
fi

# Deployer l'Application ArgoCD pour Vault
echo "[1/6] Deploiement de l'Application ArgoCD pour Vault..."
kubectl apply -f application.yaml

# Attendre que les pods Vault soient prets (Running, meme si pas Ready car pas encore unseal)
echo "[2/6] Attente du demarrage des pods Vault (peut prendre 2-3 minutes)..."
echo "  Note : les pods seront Running mais pas Ready tant que Vault n'est pas unseal."
sleep 10
kubectl wait --for=condition=Initialized pods -l app.kubernetes.io/name=vault -n vault --timeout=180s 2>/dev/null || true

# Attendre specifiquement que vault-0 soit Running
echo "  Attente de vault-0..."
for i in $(seq 1 60); do
  STATUS=$(kubectl get pod vault-0 -n vault -o jsonpath='{.status.phase}' 2>/dev/null || echo "Pending")
  if [ "$STATUS" = "Running" ]; then
    echo "  vault-0 est Running."
    break
  fi
  sleep 5
done

# Initialisation de Vault
echo "[3/6] Initialisation de Vault (operator init)..."
if kubectl exec vault-0 -n vault -- vault status 2>/dev/null | grep -q "Initialized.*true"; then
  echo "  Vault est deja initialise."
  if [ ! -f cluster-keys.json ]; then
    echo "  ATTENTION : cluster-keys.json introuvable. Si vous avez perdu vos cles, il faudra reinstaller Vault."
  fi
else
  kubectl exec vault-0 -n vault -- vault operator init \
    -key-shares=1 \
    -key-threshold=1 \
    -format=json > cluster-keys.json
  echo "  Cles sauvegardees dans cluster-keys.json (NE PAS committer ce fichier !)"
fi

# Recuperation de la cle d'unseal
VAULT_UNSEAL_KEY=$(jq -r ".unseal_keys_b64[0]" cluster-keys.json)

# Unseal du premier noeud
echo "[4/6] Unseal de vault-0..."
kubectl exec vault-0 -n vault -- vault operator unseal "$VAULT_UNSEAL_KEY"

# Jonction et unseal des noeuds secondaires
echo "[5/6] Jonction et unseal de vault-1 et vault-2..."
for i in 1 2; do
  echo "  Attente de vault-$i..."
  for j in $(seq 1 30); do
    STATUS=$(kubectl get pod vault-$i -n vault -o jsonpath='{.status.phase}' 2>/dev/null || echo "Pending")
    if [ "$STATUS" = "Running" ]; then
      break
    fi
    sleep 5
  done

  kubectl exec vault-$i -n vault -- vault operator raft join http://vault-0.vault-internal:8200
  kubectl exec vault-$i -n vault -- vault operator unseal "$VAULT_UNSEAL_KEY"
done

# Verification
echo "[6/6] Verification..."
echo ""
echo "--- Statut de Vault ---"
kubectl exec vault-0 -n vault -- vault status
echo ""
echo "--- Pods Vault ---"
kubectl get pods -n vault
echo ""
echo "--- Application ArgoCD ---"
kubectl get application vault -n argocd

ROOT_TOKEN=$(jq -r ".root_token" cluster-keys.json)
echo ""
echo "=== Vault est pret ! ==="
echo "Root token : $ROOT_TOKEN"
echo ""
echo "Pour acceder a l'interface web :"
echo "  kubectl port-forward svc/vault 8200:8200 -n vault"
echo "  Ouvrir : http://localhost:8200"
