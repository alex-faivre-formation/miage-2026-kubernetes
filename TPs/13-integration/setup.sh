#!/bin/bash
# TP13 - Integration complete : Vault -> ESO -> PostgreSQL
set -e

echo "=== TP13 : Integration Vault / ESO / PostgreSQL ==="

# Verifier les prerequis
if ! kubectl exec vault-0 -n vault -- vault status &>/dev/null; then
  echo "ERREUR : Vault n'est pas operationnel. Completez d'abord le TP11."
  exit 1
fi

if ! kubectl get clustersecretstore vault-backend &>/dev/null; then
  echo "ERREUR : Le ClusterSecretStore n'est pas configure. Completez d'abord le TP12."
  exit 1
fi

# Recuperer le root token
if [ -f ../11-vault-argocd/cluster-keys.json ]; then
  ROOT_TOKEN=$(jq -r ".root_token" ../11-vault-argocd/cluster-keys.json)
else
  echo "ERREUR : cluster-keys.json introuvable dans ../11-vault-argocd/"
  exit 1
fi

# Ecrire les credentials PostgreSQL dans Vault
echo "[1/4] Ecriture des credentials PostgreSQL dans Vault..."
kubectl exec vault-0 -n vault -- vault login "$ROOT_TOKEN" > /dev/null
kubectl exec vault-0 -n vault -- vault kv put secret/postgres-credentials \
  username="testuser" \
  password="testpassword"
echo "  Secret 'secret/postgres-credentials' cree dans Vault."

# Verification
kubectl exec vault-0 -n vault -- vault kv get secret/postgres-credentials

# Deployer la stack
echo "[2/4] Deploiement de la stack PostgreSQL..."
kubectl apply -f namespace.yaml
kubectl apply -f external-secret.yaml
kubectl apply -f configmap.yaml
kubectl apply -f pv.yaml
kubectl apply -f pvc.yaml
kubectl apply -f deployment.yaml
kubectl apply -f service.yaml

# Attendre que l'ExternalSecret soit synchronise
echo "[3/4] Attente de la synchronisation de l'ExternalSecret..."
for i in $(seq 1 30); do
  STATUS=$(kubectl get externalsecret db-credentials -n integration -o jsonpath='{.status.conditions[0].reason}' 2>/dev/null || echo "Pending")
  if [ "$STATUS" = "SecretSynced" ]; then
    echo "  ExternalSecret synchronise !"
    break
  fi
  echo "  Statut : $STATUS (attente...)"
  sleep 5
done

# Attendre que PostgreSQL soit pret
echo "[4/4] Attente du demarrage de PostgreSQL..."
kubectl wait --for=condition=Ready pods -l app=postgresdb -n integration --timeout=120s

echo ""
echo "--- ExternalSecret ---"
kubectl get externalsecret -n integration
echo ""
echo "--- Secret genere par ESO ---"
kubectl get secret db-credentials -n integration
echo ""
echo "--- Pods ---"
kubectl get pods -n integration
echo ""

# Test de connexion
POD=$(kubectl get pod -l app=postgresdb -n integration -o jsonpath='{.items[0].metadata.name}')
echo "--- Test de connexion PostgreSQL ---"
kubectl exec "$POD" -n integration -- psql -U testuser -d testdb -c "SELECT 1 AS test;"

echo ""
echo "=== Integration reussie ! ==="
echo ""
echo "Le Secret 'db-credentials' est gere automatiquement par ESO depuis Vault."
echo ""
echo "=== Exercice : Rotation de secrets ==="
echo ""
echo "1. Modifier le mot de passe dans Vault :"
echo "   kubectl exec vault-0 -n vault -- vault kv put secret/postgres-credentials username=testuser password=newpassword"
echo ""
echo "2. Attendre 15 secondes (refreshInterval de l'ExternalSecret)"
echo ""
echo "3. Verifier que le Secret Kubernetes est mis a jour :"
echo "   kubectl get secret db-credentials -n integration -o jsonpath='{.data.POSTGRES_PASSWORD}' | base64 -d"
