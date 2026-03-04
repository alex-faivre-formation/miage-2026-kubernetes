#!/bin/bash
# Installation de l'Ingress Controller NGINX via Helm

helm upgrade --install ingress-nginx ingress-nginx \
  --repo https://kubernetes.github.io/ingress-nginx \
  --namespace ingress-nginx --create-namespace

echo "Vérification du déploiement:"
kubectl get pods -n ingress-nginx
kubectl get svc -n ingress-nginx
