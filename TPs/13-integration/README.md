# TP13 - Integration -- Vault, ESO et PostgreSQL

## Introduction theorique

Ce TP est l'aboutissement des TPs 11 et 12. Il deploie une base de donnees PostgreSQL dont les **credentials sont gerees par Vault** et synchronisees automatiquement vers Kubernetes par **External Secrets Operator**. Plus aucun mot de passe n'est stocke en clair dans les fichiers YAML.

### Comparaison avec le TP02

```
  TP02 (Secrets en clair)                TP13 (Secrets via Vault)
  =======================                ========================

  configmap.yaml                         configmap.yaml
  +-----------------+                    +-----------------+
  | POSTGRES_DB     |                    | POSTGRES_DB     |  (seul le non-sensible)
  | POSTGRES_USER   |  <-- sensible !    +-----------------+
  | POSTGRES_PASSWORD|  <-- sensible !
  +-----------------+                    Vault (source de verite)
                                         +-----------------+
  OU                                     | username        |
                                         | password        |
  secret.yaml                            +-----------------+
  +-----------------+                           |
  | base64 encoded  |  <-- pas chiffre !        | ESO synchronise
  +-----------------+                           v
                                         Secret K8s (auto-genere)
                                         +-----------------+
                                         | POSTGRES_USER   |
                                         | POSTGRES_PASSWORD|
                                         +-----------------+
```

**Differences cles :**
- Le ConfigMap ne contient plus que `POSTGRES_DB` (donnee non sensible)
- Les credentials (`POSTGRES_USER`, `POSTGRES_PASSWORD`) sont dans Vault
- Le Secret Kubernetes est **cree dynamiquement** par ESO -- il n'existe pas comme fichier YAML dans Git
- La rotation des secrets est automatique (toutes les 15 secondes dans ce TP)

### Flux complet

```
+----------+       +-----+       +-------------------+       +----------+
|  Admin   | ----> | Vault| ----> | External Secrets  | ----> | Secret   |
|          | ecrit | KV v2| lit   | Operator          | cree  | K8s      |
| vault kv |       |      |       | (ExternalSecret)  |       | db-creds |
| put ...  |       |      |       | refreshInterval:  |       |          |
+----------+       +-----+       | 15s               |       +----------+
                                  +-------------------+            |
                                                                   v
                                                            +----------+
                                                            | Pod      |
                                                            | Postgres |
                                                            | envFrom: |
                                                            | secretRef|
                                                            +----------+
```

### Rotation de secrets

L'un des avantages majeurs de cette architecture est la **rotation automatique** des secrets :

1. L'admin modifie le secret dans Vault (`vault kv put ...`)
2. ESO detecte le changement lors du prochain `refreshInterval` (15s)
3. ESO met a jour le Secret Kubernetes
4. Le pod peut etre redemarrer pour prendre en compte les nouvelles valeurs

**Note** : PostgreSQL ne relit pas automatiquement les variables d'environnement. Pour une rotation complete, il faut redemarrer le pod. En production, on utilise des mecanismes comme les [Reloader](https://github.com/stakater/Reloader) pour automatiser le redemarrage.

## Objectifs

- Deployer une stack PostgreSQL complete avec des secrets geres par Vault
- Comprendre la separation entre donnees sensibles (Vault) et non-sensibles (ConfigMap)
- Observer la synchronisation automatique ESO -> Secret Kubernetes
- Pratiquer la rotation de secrets

## Prerequis

- Un cluster Kubernetes fonctionnel (minikube)
- Vault deploye et unseal (TP11)
- External Secrets Operator configure avec ClusterSecretStore (TP12)
- `kubectl`, `jq` installes

## Architecture deployee

```
Cluster Kubernetes
+-------------------------------------------------------------------+
|                                                                   |
|  Namespace: vault                                                 |
|  +-------------------------------------------------------------+ |
|  | Vault (HA/Raft)                                              | |
|  | secret/postgres-credentials:                                 | |
|  |   username: testuser                                         | |
|  |   password: testpassword                                     | |
|  +-------------------------------------------------------------+ |
|         ^                                                         |
|         | ESO lit les secrets                                     |
|                                                                   |
|  Namespace: integration                                           |
|  +-------------------------------------------------------------+ |
|  |                                                              | |
|  |  ExternalSecret         Secret (auto)      ConfigMap         | |
|  |  "db-credentials"  -->  "db-credentials"   "db-config"      | |
|  |  (refreshInterval:      POSTGRES_USER       POSTGRES_DB      | |
|  |   15s)                  POSTGRES_PASSWORD                    | |
|  |                              |                   |           | |
|  |                              +-------+-----------+           | |
|  |                                      |                       | |
|  |                                      v                       | |
|  |                          +---------------------+             | |
|  |                          | Deployment          |             | |
|  |                          | postgresdb          |             | |
|  |                          | envFrom:            |             | |
|  |                          |  - configMapRef     |             | |
|  |                          |  - secretRef        |             | |
|  |                          +---------------------+             | |
|  |                                   |                          | |
|  |                          +--------+--------+                 | |
|  |                          | Service :5432   |                 | |
|  |                          | PVC integration |                 | |
|  |                          +-----------------+                 | |
|  +-------------------------------------------------------------+ |
+-------------------------------------------------------------------+
```

## Fichiers et explication detaillee

### `namespace.yaml` -- Namespace dedie

Un namespace `integration` separe pour eviter les conflits avec le TP02 (`postgres`).

### `external-secret.yaml` -- ExternalSecret

```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: db-credentials
  namespace: integration
spec:
  refreshInterval: 15s                # Verifie Vault toutes les 15 secondes
  secretStoreRef:
    name: vault-backend               # Reference le ClusterSecretStore du TP12
    kind: ClusterSecretStore
  target:
    name: db-credentials              # Nom du Secret K8s qui sera cree
    creationPolicy: Owner             # ESO est proprietaire du Secret
  data:
    - secretKey: POSTGRES_USER        # Cle dans le Secret K8s
      remoteRef:
        key: secret/postgres-credentials  # Path dans Vault
        property: username                # Propriete dans le secret Vault
    - secretKey: POSTGRES_PASSWORD
      remoteRef:
        key: secret/postgres-credentials
        property: password
```

**Points cles :**
- `refreshInterval: 15s` : ESO verifie Vault toutes les 15s. En production, 1h ou plus est recommande.
- `creationPolicy: Owner` : si l'ExternalSecret est supprime, le Secret K8s est aussi supprime.
- Le mapping `secretKey` -> `remoteRef` transforme les noms : `username` dans Vault devient `POSTGRES_USER` dans le Secret K8s.

### `configmap.yaml` -- Donnees non-sensibles uniquement

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: db-config
  namespace: integration
data:
  POSTGRES_DB: testdb    # Seule donnee non-sensible
```

**Difference avec le TP02** : le ConfigMap du TP02 contenait `POSTGRES_USER` et `POSTGRES_PASSWORD`. Ici, ces valeurs sont dans Vault.

### `deployment.yaml` -- PostgreSQL avec deux sources d'env

```yaml
envFrom:
  - configMapRef:
      name: db-config           # POSTGRES_DB
  - secretRef:
      name: db-credentials      # POSTGRES_USER + POSTGRES_PASSWORD (genere par ESO)
```

Le Deployment combine deux sources : le ConfigMap pour les donnees non-sensibles et le Secret (genere par ESO) pour les credentials.

### `pv.yaml` / `pvc.yaml` -- Stockage dedie

Nommes `integration-pv` et `integration-pvc` avec `hostPath: /data/integration-db` pour eviter les collisions avec le TP02 (`pv` + `/data/db`).

## Deploiement pas a pas

### 1. Executer le script de setup

```bash
# Depuis le dossier TPs/13-integration/
./setup.sh
```

### 2. Ou deployer manuellement

```bash
# Ecrire les credentials dans Vault
ROOT_TOKEN=$(jq -r ".root_token" ../11-vault-argocd/cluster-keys.json)
kubectl exec vault-0 -n vault -- vault login "$ROOT_TOKEN"
kubectl exec vault-0 -n vault -- vault kv put secret/postgres-credentials \
  username="testuser" password="testpassword"

# Deployer la stack
kubectl apply -f namespace.yaml
kubectl apply -f external-secret.yaml
kubectl apply -f configmap.yaml
kubectl apply -f pv.yaml
kubectl apply -f pvc.yaml
kubectl apply -f deployment.yaml
kubectl apply -f service.yaml

# Verifier
kubectl get externalsecret -n integration
kubectl get secret db-credentials -n integration
kubectl get pods -n integration
```

### 3. Verifier

```bash
# ExternalSecret synchronise
kubectl get externalsecret -n integration
```

Sortie attendue :
```
NAME             STORE           REFRESH INTERVAL   STATUS         READY
db-credentials   vault-backend   15s                SecretSynced   True
```

```bash
# Secret genere par ESO
kubectl get secret db-credentials -n integration -o jsonpath='{.data}' | python3 -m json.tool
```

```bash
# Pod PostgreSQL Running
kubectl get pods -n integration
```

```bash
# Test de connexion
POD=$(kubectl get pod -l app=postgresdb -n integration -o jsonpath='{.items[0].metadata.name}')
kubectl exec "$POD" -n integration -- psql -U testuser -d testdb -c "SELECT 1 AS test;"
```

Sortie attendue :
```
 test
------
    1
(1 row)
```

## Exercice : Rotation de secrets

C'est l'exercice principal de ce TP. Il demontre la rotation automatique des secrets.

### Etape 1 : Verifier le mot de passe actuel

```bash
kubectl get secret db-credentials -n integration \
  -o jsonpath='{.data.POSTGRES_PASSWORD}' | base64 -d
# Affiche : testpassword
```

### Etape 2 : Modifier le mot de passe dans Vault

```bash
kubectl exec vault-0 -n vault -- vault kv put secret/postgres-credentials \
  username="testuser" password="newpassword123"
```

### Etape 3 : Attendre la synchronisation (15 secondes)

```bash
sleep 20
```

### Etape 4 : Verifier que le Secret Kubernetes est mis a jour

```bash
kubectl get secret db-credentials -n integration \
  -o jsonpath='{.data.POSTGRES_PASSWORD}' | base64 -d
# Affiche : newpassword123
```

**Le Secret Kubernetes a ete mis a jour automatiquement par ESO !**

### Etape 5 : Observer l'impact sur PostgreSQL

Le pod PostgreSQL utilise toujours l'ancien mot de passe (celui avec lequel il a demarre). Pour appliquer le nouveau :

```bash
# Redemarrer le pod
kubectl rollout restart deployment/postgresdb -n integration

# Attendre le redemarrage
kubectl rollout status deployment/postgresdb -n integration
```

**Note** : en production, on utiliserait [Stakater Reloader](https://github.com/stakater/Reloader) pour detecter automatiquement les changements de Secrets et redemarrer les pods concernes.

## Troubleshooting

### L'ExternalSecret est en "SecretSyncedError"

**Cause probable** : le secret n'existe pas dans Vault ou le path est incorrect.
```bash
kubectl describe externalsecret db-credentials -n integration
# Chercher le message d'erreur

# Verifier le secret dans Vault
kubectl exec vault-0 -n vault -- vault kv get secret/postgres-credentials
```

### Le Secret K8s n'est pas cree

**Cause probable** : le ClusterSecretStore n'est pas valide.
```bash
kubectl get clustersecretstore vault-backend
# Doit afficher "Valid"
```

### Le pod PostgreSQL est en CrashLoopBackOff

**Cause probable** : les variables d'environnement sont manquantes ou incorrectes.
```bash
kubectl describe pod -l app=postgresdb -n integration
kubectl logs -l app=postgresdb -n integration
```

**Verifier que le Secret contient les bonnes cles :**
```bash
kubectl get secret db-credentials -n integration -o yaml
# Doit contenir POSTGRES_USER et POSTGRES_PASSWORD
```

### Le PV ne se bind pas au PVC

**Cause probable** : collision de noms avec le TP02.
```bash
kubectl get pv
# Verifier que "integration-pv" existe et est Available ou Bound
```

## Nettoyage

```bash
# Supprimer les ressources du namespace integration
kubectl delete -f service.yaml
kubectl delete -f deployment.yaml
kubectl delete -f pvc.yaml
kubectl delete -f pv.yaml
kubectl delete -f configmap.yaml
kubectl delete -f external-secret.yaml
kubectl delete -f namespace.yaml

# Supprimer le secret dans Vault
kubectl exec vault-0 -n vault -- vault kv delete secret/postgres-credentials
```

## Pour aller plus loin

- [ESO ExternalSecret documentation](https://external-secrets.io/latest/api/externalsecret/)
- [Stakater Reloader](https://github.com/stakater/Reloader) pour le redemarrage automatique des pods
- [Vault Dynamic Secrets](https://developer.hashicorp.com/vault/docs/secrets/databases) pour generer des credentials PostgreSQL a duree de vie limitee
- Configurer une politique Vault restrictive (au lieu du root token) pour limiter l'acces aux secrets

## QCM de revision

**Question 1** : Pourquoi le Secret `db-credentials` n'existe-t-il pas comme fichier YAML dans le depot Git ?

- A) Parce qu'on l'a oublie
- B) Parce qu'il est cree dynamiquement par External Secrets Operator depuis Vault
- C) Parce que Kubernetes le genere automatiquement
- D) Parce qu'il est stocke dans un ConfigMap

<details>
<summary>Reponse</summary>
<b>B)</b> L'<code>ExternalSecret</code> declare quel secret recuperer depuis Vault et ESO cree automatiquement le Secret Kubernetes correspondant. Le Secret n'a jamais besoin d'exister dans Git, ce qui evite d'exposer des credentials dans le depot.
</details>

---

**Question 2** : Quelle est la difference entre le ConfigMap `db-config` du TP13 et le ConfigMap `credentials` du TP02 ?

- A) Ils sont identiques
- B) Le ConfigMap du TP13 ne contient que `POSTGRES_DB` (non-sensible), les credentials sont dans Vault
- C) Le ConfigMap du TP13 contient des donnees chiffrees
- D) Le ConfigMap du TP02 est plus securise car il utilise des labels

<details>
<summary>Reponse</summary>
<b>B)</b> Le TP02 stockait <code>POSTGRES_USER</code> et <code>POSTGRES_PASSWORD</code> directement dans le ConfigMap (en clair dans Git). Le TP13 separe les donnees : seul <code>POSTGRES_DB</code> (non-sensible) reste dans le ConfigMap, les credentials sont dans Vault et synchronisees par ESO.
</details>

---

**Question 3** : Que signifie `refreshInterval: 15s` dans l'ExternalSecret ?

- A) Le pod PostgreSQL redemarre toutes les 15 secondes
- B) ESO verifie Vault toutes les 15 secondes et met a jour le Secret K8s si le secret Vault a change
- C) Vault fait une rotation automatique du mot de passe toutes les 15 secondes
- D) Le Secret Kubernetes expire apres 15 secondes

<details>
<summary>Reponse</summary>
<b>B)</b> <code>refreshInterval: 15s</code> indique a ESO de verifier le secret dans Vault toutes les 15 secondes. Si la valeur a change, le Secret Kubernetes est automatiquement mis a jour. En production, un intervalle plus long (1h, 24h) est recommande.
</details>

---

**Question 4** : Apres avoir modifie un secret dans Vault, pourquoi le pod PostgreSQL utilise-t-il encore l'ancien mot de passe ?

- A) Parce qu'ESO ne fonctionne pas correctement
- B) Parce que les variables d'environnement sont lues au demarrage du conteneur et ne sont pas rechargees dynamiquement
- C) Parce que PostgreSQL cache les mots de passe
- D) Parce que le Secret Kubernetes n'est pas mis a jour

<details>
<summary>Reponse</summary>
<b>B)</b> Les variables d'environnement injectees via <code>envFrom</code> sont lues au demarrage du conteneur. Meme si le Secret Kubernetes est mis a jour par ESO, le conteneur en cours d'execution garde les anciennes valeurs en memoire. Un redemarrage du pod (<code>kubectl rollout restart</code>) est necessaire.
</details>

---

**Question 5** : Quel est l'avantage principal de `creationPolicy: Owner` dans l'ExternalSecret ?

- A) Le Secret est cree plus rapidement
- B) Si l'ExternalSecret est supprime, le Secret Kubernetes associe est automatiquement supprime (garbage collection)
- C) Le Secret est accessible depuis tous les namespaces
- D) Le Secret est chiffre dans etcd

<details>
<summary>Reponse</summary>
<b>B)</b> <code>creationPolicy: Owner</code> fait de l'ExternalSecret le "owner" du Secret Kubernetes via les <code>ownerReferences</code>. Quand l'ExternalSecret est supprime, le garbage collector Kubernetes supprime automatiquement le Secret orphelin.
</details>
