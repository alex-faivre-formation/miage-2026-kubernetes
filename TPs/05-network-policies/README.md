# TP05 - NetworkPolicy — Isolation réseau des pods

## Objectifs
- Bloquer tout le trafic entrant par défaut (deny-all)
- Autoriser uniquement le trafic légitime (whitelist)
- Comprendre la combinaison des selectors (AND vs OR)

## Prérequis
- Namespace `postgres` existant avec des pods PostgreSQL (TP02)
- **CNI compatible** : Calico, Cilium ou Weave Net. Flannel et le CNI par défaut de minikube ne supportent PAS les NetworkPolicies.

> Pour activer les NetworkPolicies sur minikube :
> ```bash
> minikube start --cni=calico
> ```

## Fichiers

| Fichier | Description |
|---------|-------------|
| `default-deny-ingress.yaml` | Bloque tout le trafic entrant vers tous les pods du namespace |
| `allow-frontend-to-db.yaml` | Autorise uniquement les pods `frontend` à accéder à PostgreSQL sur le port 5432 |

## Déploiement

### 1. Appliquer le deny-all
```bash
kubectl apply -f default-deny-ingress.yaml
```

Tous les pods du namespace `postgres` sont maintenant isolés : aucun trafic entrant n'est autorisé.

### 2. Autoriser le frontend vers la DB
```bash
kubectl apply -f allow-frontend-to-db.yaml
```

Seuls les pods avec le label `app: frontend` dans le namespace `frontend` peuvent accéder aux pods `app: postgresdb` sur le port TCP 5432.

### 3. Vérifier
```bash
kubectl get networkpolicies -n postgres
kubectl describe networkpolicy allow-frontend-to-db -n postgres
```

## Logique de combinaison des selectors

Dans une NetworkPolicy :
- **Entrées séparées dans `from`** = combinées en **OU** (OR)
- **`namespaceSelector` + `podSelector` dans la même entrée** = combinées en **ET** (AND)

Exemple dans notre manifest :
```yaml
ingress:
  - from:
      - namespaceSelector:         # ET
          matchLabels:
            kubernetes.io/metadata.name: frontend
        podSelector:               # ET
          matchLabels:
            app: frontend
```
→ Le pod doit être dans le namespace `frontend` **ET** avoir le label `app: frontend`.

## Bonne pratique
1. Commencer par un **deny-all** sur chaque namespace
2. Ouvrir uniquement les flux nécessaires
3. Documenter chaque règle

## Nettoyage
```bash
kubectl delete -f allow-frontend-to-db.yaml
kubectl delete -f default-deny-ingress.yaml
```
