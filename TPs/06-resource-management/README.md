# TP06 - Gestion des ressources, autoscaling et scheduling

## Objectifs
- Définir des quotas de ressources par namespace (ResourceQuota)
- Configurer des limites par défaut par conteneur (LimitRange)
- Mettre en place l'autoscaling horizontal (HPA)
- Contrôler le placement des pods avec Taints/Tolerations et Node Affinity

## Prérequis
- Namespace `postgres` existant avec un Deployment PostgreSQL (TP02)
- Metrics Server installé pour le HPA (`kubectl top nodes` doit fonctionner)

## Fichiers

| Fichier | Description |
|---------|-------------|
| `resourcequota.yaml` | Quotas globaux du namespace postgres (CPU, mémoire, pods, PVC, services) |
| `limitrange.yaml` | Limites par conteneur : valeurs par défaut, min et max |
| `hpa.yaml` | HorizontalPodAutoscaler ciblant le Deployment postgresdb |
| `taints-tolerations.yaml` | Pod avec Toleration pour noeuds GPU |
| `node-affinity.yaml` | Pod avec Node Affinity (architecture amd64, préférence SSD) |

## Déploiement et tests

### ResourceQuota
```bash
kubectl apply -f resourcequota.yaml

# Voir la consommation vs quotas
kubectl describe quota -n postgres
```

> Une fois la ResourceQuota active, **tous les pods** du namespace doivent déclarer des `resources.requests`, sinon leur création sera refusée.

### LimitRange
```bash
kubectl apply -f limitrange.yaml

# Vérifier les limites
kubectl describe limitrange limits-postgres -n postgres
```

Les pods qui ne déclarent pas de resources recevront automatiquement :
- `requests.cpu: 100m`, `requests.memory: 128Mi`
- `limits.cpu: 500m`, `limits.memory: 256Mi`

### HPA — Horizontal Pod Autoscaler
```bash
kubectl apply -f hpa.yaml

# Suivre l'état du HPA
kubectl get hpa -n postgres

# Forme impérative équivalente
kubectl autoscale deployment postgresdb \
  --cpu-percent=70 --min=2 --max=10 -n postgres
```

Le HPA scale entre 2 et 10 replicas selon :
- CPU moyen > 70% → scale out
- Mémoire moyenne > 80% → scale out

### Taints et Tolerations
```bash
# Ajouter une taint sur un noeud
kubectl taint nodes <node-name> gpu=true:NoSchedule

# Déployer un pod avec la Toleration correspondante
kubectl apply -f taints-tolerations.yaml

# Retirer la taint
kubectl taint nodes <node-name> gpu=true:NoSchedule-
```

### Node Affinity
```bash
# Valider le manifest (dry-run car les labels peuvent ne pas matcher)
kubectl apply --dry-run=server -f node-affinity.yaml
```

| Type | Comportement |
|------|-------------|
| `requiredDuringSchedulingIgnoredDuringExecution` | Obligation (hard) — le pod n'est pas schedulé si aucun noeud ne matche |
| `preferredDuringSchedulingIgnoredDuringExecution` | Préférence (soft) — le scheduler essaie, mais s'adapte |

## Récapitulatif

| Ressource | Scope | Effet |
|-----------|-------|-------|
| ResourceQuota | Namespace | Total de ressources consommables |
| LimitRange | Namespace | Limites par conteneur (défaut, min, max) |
| HPA | Deployment | Autoscaling basé sur les métriques |
| Taint | Noeud | Repousse les pods sans Toleration |
| Toleration | Pod | Permet d'ignorer une Taint |
| Node Affinity | Pod | Attire vers des noeuds spécifiques |

## Nettoyage
```bash
kubectl delete -f hpa.yaml
kubectl delete -f limitrange.yaml
kubectl delete -f resourcequota.yaml
```
