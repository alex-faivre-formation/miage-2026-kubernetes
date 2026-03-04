#!/bin/bash
# TP12 - Installation d'External Secrets Operator et configuration du ClusterSecretStore
set -e

echo "=== TP12 : External Secrets Operator ==="

# Verifier que Vault est operationnel
if ! kubectl exec vault-0 -n vault -- vault status &>/dev/null; then
  echo "ERREUR : Vault n'est pas operationnel. Completez d'abord le TP11."
  exit 1
fi

# Verifier que cluster-keys.json existe (depuis le TP11)
if [ ! -f ../11-vault-argocd/cluster-keys.json ]; then
  echo "ERREUR : cluster-keys.json introuvable dans ../11-vault-argocd/"
  echo "Assurez-vous d'avoir complete le TP11."
  exit 1
fi

ROOT_TOKEN=$(jq -r ".root_token" ../11-vault-argocd/cluster-keys.json)

# Deployer ESO via ArgoCD
echo "[1/5] Deploiement d'External Secrets Operator via ArgoCD..."
kubectl apply -f application.yaml

# Attendre que les pods ESO soient prets
echo "[2/5] Attente du demarrage d'ESO (peut prendre 1-2 minutes)..."
sleep 15
kubectl wait --for=condition=Ready pods -l app.kubernetes.io/name=external-secrets -n external-secrets --timeout=180s 2>/dev/null || true
kubectl wait --for=condition=Ready pods -l app.kubernetes.io/name=external-secrets-webhook -n external-secrets --timeout=180s 2>/dev/null || true
kubectl wait --for=condition=Ready pods -l app.kubernetes.io/name=external-secrets-cert-controller -n external-secrets --timeout=180s 2>/dev/null || true

echo "--- Pods ESO ---"
kubectl get pods -n external-secrets

# Activer le moteur de secrets KV v2 dans Vault
echo "[3/5] Activation du moteur de secrets KV v2 dans Vault..."
kubectl exec vault-0 -n vault -- vault login "$ROOT_TOKEN" > /dev/null
kubectl exec vault-0 -n vault -- vault secrets enable -path=secret kv-v2 2>/dev/null || echo "  KV v2 deja active sur le path 'secret'."

# Ecrire un secret de test
echo "[4/5] Ecriture d'un secret de test dans Vault..."
kubectl exec vault-0 -n vault -- vault kv put secret/test-secret username="demo-user" password="demo-password"
echo "  Secret 'secret/test-secret' cree."

# Verification du secret de test
kubectl exec vault-0 -n vault -- vault kv get secret/test-secret

# Creer le Secret Kubernetes contenant le token Vault pour ESO
echo "[5/5] Configuration du ClusterSecretStore..."
kubectl create secret generic vault-token \
  --from-literal=token="$ROOT_TOKEN" \
  -n external-secrets \
  --dry-run=client -o yaml | kubectl apply -f -

# Appliquer le ClusterSecretStore
kubectl apply -f cluster-secret-store.yaml

# Attendre la validation
sleep 5
echo ""
echo "--- ClusterSecretStore ---"
kubectl get clustersecretstore vault-backend
echo ""
echo "--- Application ArgoCD ---"
kubectl get application external-secrets -n argocd
echo ""
echo "=== External Secrets Operator est pret ! ==="
echo ""
echo "Le ClusterSecretStore 'vault-backend' est connecte a Vault."
echo "Vous pouvez maintenant creer des ExternalSecrets dans n'importe quel namespace."
