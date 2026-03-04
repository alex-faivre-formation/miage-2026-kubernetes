# TP01 - Déploiement d'un conteneur Nginx

## Objectifs
- Créer un namespace Kubernetes
- Déployer un pod nginx avec des contraintes de ressources
- Exposer le pod via un Service LoadBalancer
- Comprendre les labels et selectors

## Prérequis
- Un cluster Kubernetes fonctionnel (minikube, Docker Desktop, etc.)
- `kubectl` installé et configuré

## Fichiers

| Fichier | Description |
|---------|-------------|
| `namespaces.yml` | Crée les namespaces `nginx` et `neuvector` |
| `nginx.yml` | Pod nginx avec limits/requests CPU et mémoire |
| `service.yml` | Service LoadBalancer exposant nginx sur le port 80 |
| `configMap.yml` | ConfigMap pour les credentials PostgreSQL |
| `secrets.yml` | Secret encodé en Base64 pour les credentials |
| `pv.yml` | PersistentVolume de 8Gi |
| `pvc.yml` | PersistentVolumeClaim lié au PV |
| `postgres.yml` | Deployment PostgreSQL avec ConfigMap et volume |

## Déploiement pas à pas

### 1. Créer les namespaces
```bash
kubectl apply -f namespaces.yml
```

### 2. Déployer le pod nginx
```bash
kubectl apply -f nginx.yml
```

### 3. Vérifier le pod
```bash
kubectl get pods -n nginx
kubectl describe pod nginx -n nginx
```

### 4. Tester l'accès via port-forward (sans service)
```bash
kubectl port-forward pod/nginx 8080:80 -n nginx
# Ouvrir http://localhost:8080 dans un navigateur
```

### 5. Exposer via un Service
```bash
kubectl apply -f service.yml
kubectl get svc -n nginx
```

### 6. (Optionnel) Déployer la stack PostgreSQL
```bash
kubectl apply -f configMap.yml
kubectl apply -f pv.yml
kubectl apply -f pvc.yml
kubectl apply -f postgres.yml
```

## Commandes utiles
```bash
# Voir les ressources du namespace
kubectl get all -n nginx

# Labels et selectors
kubectl get pods -l app=nginx -n nginx

# Ajouter un label
kubectl label pod nginx env=dev -n nginx

# Supprimer un label
kubectl label pod nginx env- -n nginx

# Ressources consommées
kubectl top pods -n nginx
```

## Nettoyage
```bash
kubectl delete -f service.yml
kubectl delete -f nginx.yml
kubectl delete namespace nginx
```

## Concepts clés
- **Pod** : plus petite unité déployable dans Kubernetes
- **Namespace** : isolation logique des ressources
- **Service LoadBalancer** : expose un service vers l'extérieur avec une IP externe
- **Labels/Selectors** : mécanisme central pour relier Services, Deployments et Pods
- **Resources requests/limits** : contrôle de la consommation CPU et mémoire
