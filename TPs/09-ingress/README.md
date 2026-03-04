# TP09 - Ingress et Harbor

## Objectifs
- Installer un Ingress Controller (NGINX)
- Comprendre le routage HTTP/HTTPS vers les services internes
- Préparer l'installation de Harbor (registry de conteneurs)

## Prérequis
- Cluster Kubernetes fonctionnel
- `helm` installé

## Fichiers

| Fichier | Description |
|---------|-------------|
| `setup-ingress-nginx.sh` | Script d'installation de l'Ingress Controller NGINX via Helm |
| `ingress-example.yaml` | Exemple de ressource Ingress routant vers nginx-service |

## Installation de l'Ingress Controller

### Via le script
```bash
chmod +x setup-ingress-nginx.sh
./setup-ingress-nginx.sh
```

### Manuellement
```bash
helm upgrade --install ingress-nginx ingress-nginx \
  --repo https://kubernetes.github.io/ingress-nginx \
  --namespace ingress-nginx --create-namespace
```

### Vérifier l'installation
```bash
kubectl get pods -n ingress-nginx
kubectl get svc -n ingress-nginx
```

Le controller doit être en état `Running`.

## Déployer un Ingress

### 1. S'assurer que le service cible existe
```bash
# Le service nginx du TP01 doit exister
kubectl get svc nginx-service -n nginx
```

### 2. Appliquer l'Ingress
```bash
kubectl apply -f ingress-example.yaml
kubectl get ingress -n nginx
```

### 3. Tester (avec minikube)
```bash
# Récupérer l'IP de minikube
minikube ip

# Ajouter l'entrée dans /etc/hosts
echo "$(minikube ip) app.example.com" | sudo tee -a /etc/hosts

# Tester
curl http://app.example.com:<node-port>
```

## Qu'est-ce qu'un Ingress ?

Un Ingress gère l'accès HTTP/HTTPS externe aux services du cluster :
- Point d'entrée unique pour le trafic externe
- Routage basé sur le hostname ou le chemin URL
- Terminaison SSL/TLS
- Plus économique que plusieurs LoadBalancers

```
Client → Ingress Controller → Service → Pod(s)
```

## Installation de Harbor

Harbor est un registry de conteneurs avec scanner de vulnérabilités intégré (Trivy).

```bash
# Ajouter le repo Helm Harbor
helm repo add harbor https://helm.goharbor.io
helm repo update

# Installer Harbor
helm upgrade --install harbor harbor/harbor \
  --namespace harbor --create-namespace \
  --set expose.type=ingress \
  --set expose.ingress.className=nginx \
  --set externalURL=https://harbor.example.com
```

## Nettoyage
```bash
kubectl delete -f ingress-example.yaml
helm uninstall ingress-nginx -n ingress-nginx
```
