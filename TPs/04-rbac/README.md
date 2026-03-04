# TP04 - RBAC — Contrôle d'accès basé sur les rôles

## Objectifs
- Créer un ServiceAccount dédié par application
- Définir des permissions précises avec Role et ClusterRole
- Lier les permissions aux identités avec RoleBinding et ClusterRoleBinding
- Vérifier les permissions avec `kubectl auth can-i`

## Prérequis
- Namespace `postgres` existant (TP02)

## Fichiers

| Fichier | Description |
|---------|-------------|
| `serviceaccount.yaml` | ServiceAccount `mon-app` dans le namespace postgres |
| `role.yaml` | Role `pod-reader` : lecture des pods et logs (namespace-scoped) |
| `rolebinding.yaml` | RoleBinding liant le Role au ServiceAccount |
| `clusterrole.yaml` | ClusterRole `node-reader` : lecture des nodes (cluster-wide) |

## Déploiement pas à pas

### 1. Créer le ServiceAccount
```bash
kubectl apply -f serviceaccount.yaml
kubectl get serviceaccounts -n postgres
```

### 2. Créer le Role (permissions namespace-scoped)
```bash
kubectl apply -f role.yaml
```

Le Role `pod-reader` autorise : `get`, `list`, `watch` sur les ressources `pods` et `pods/log` dans le namespace `postgres`.

### 3. Lier le Role au ServiceAccount
```bash
kubectl apply -f rolebinding.yaml
```

### 4. Créer le ClusterRole (permissions cluster-wide)
```bash
kubectl apply -f clusterrole.yaml
```

### 5. Vérifier les permissions
```bash
# Le ServiceAccount peut-il lister les pods ? → yes
kubectl auth can-i list pods \
  --as=system:serviceaccount:postgres:mon-app \
  -n postgres

# Le ServiceAccount peut-il supprimer des pods ? → no
kubectl auth can-i delete pods \
  --as=system:serviceaccount:postgres:mon-app \
  -n postgres

# Le ServiceAccount peut-il voir les logs ? → yes
kubectl auth can-i get pods/log \
  --as=system:serviceaccount:postgres:mon-app \
  -n postgres
```

## Formes impératives (plus rapides à la CKAD)
```bash
# Créer un Role
kubectl create role pod-reader \
  --verb=get,list,watch \
  --resource=pods \
  -n postgres

# Créer un RoleBinding
kubectl create rolebinding read-pods \
  --role=pod-reader \
  --serviceaccount=postgres:mon-app \
  -n postgres
```

## Architecture RBAC

```
ServiceAccount (identité du pod)
    │
    ├── lié par RoleBinding ──► Role (verbes + ressources, namespace-scoped)
    │
    └── lié par ClusterRoleBinding ──► ClusterRole (cluster-wide)
```

## Verbes RBAC courants

| Verbe | Description |
|-------|-------------|
| `get` | Lire une ressource spécifique |
| `list` | Lister les ressources |
| `watch` | Surveiller les changements (flag `-w`) |
| `create` | Créer une ressource |
| `update` | Modifier une ressource existante |
| `patch` | Modification partielle (utilisé par `kubectl apply`) |
| `delete` | Supprimer une ressource |

## Nettoyage
```bash
kubectl delete -f rolebinding.yaml
kubectl delete -f role.yaml
kubectl delete -f serviceaccount.yaml
kubectl delete -f clusterrole.yaml
```
