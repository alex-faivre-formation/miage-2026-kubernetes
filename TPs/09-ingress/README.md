# TP09 - Ingress Controller et Harbor

## Introduction theorique

Ce TP couvre le routage du trafic HTTP/HTTPS externe vers les services internes du cluster grace a l'**Ingress** et l'**Ingress Controller**. Nous installerons egalement **Harbor**, un registre de conteneurs prive avec scanner de vulnerabilites integre.

### Le probleme : comment exposer des services HTTP ?

Sans Ingress, chaque service web necessite son propre LoadBalancer (ou NodePort). Cela pose plusieurs problemes :

```
  Sans Ingress (cout eleve, pas de routage intelligent)
  =====================================================

  Client --> LB1 ($$$) --> Service A (port 80)
  Client --> LB2 ($$$) --> Service B (port 80)
  Client --> LB3 ($$$) --> Service C (port 80)

  Avec Ingress (un seul LB, routage par hostname/path)
  ====================================================

  Client --> LB unique --> Ingress Controller --> Service A (app.example.com)
                                              --> Service B (api.example.com)
                                              --> Service C (app.example.com/admin)
```

- **Sans Ingress** : chaque service expose necessite un LoadBalancer dedie. Chez un cloud provider, chaque LB coute de l'argent et possede sa propre IP publique.
- **Avec Ingress** : un seul LoadBalancer devant l'Ingress Controller, qui route le trafic vers les bons services en fonction du hostname ou du chemin URL.

### Qu'est-ce qu'un Ingress ?

L'**Ingress** est une ressource Kubernetes declarative (API `networking.k8s.io/v1`) qui definit des regles de routage HTTP/HTTPS. A lui seul, un Ingress ne fait rien -- il necessite un **Ingress Controller** pour etre effectif.

Les fonctionnalites principales :
- **Routage par hostname** : `app.example.com` --> Service A, `api.example.com` --> Service B
- **Routage par chemin** : `/api` --> Service API, `/` --> Service Frontend
- **Terminaison TLS/SSL** : HTTPS s'arrete au niveau de l'Ingress, le trafic interne reste en HTTP
- **Rewrite d'URL** : transformer `/api/v1/users` en `/users` avant d'envoyer au backend

### Qu'est-ce qu'un Ingress Controller ?

L'**Ingress Controller** est un composant (generalement un reverse proxy comme NGINX, Traefik ou HAProxy) deploye dans le cluster qui :
1. Surveille les ressources Ingress via l'API Kubernetes
2. Configure automatiquement ses regles de routage en consequence
3. Recoit le trafic entrant et le route vers les bons services

```
                         Cluster Kubernetes
+----------------------------------------------------------------------+
|                                                                      |
|  Namespace: ingress-nginx                                            |
|  +----------------------------------------------------------------+  |
|  |                                                                |  |
|  |  +--------------------+    surveille    +------------------+   |  |
|  |  | Ingress Controller | <-------------- | Ingress (regles) |   |  |
|  |  | (NGINX Pod)        |                 | networking.k8s.io|   |  |
|  |  +--------------------+                 +------------------+   |  |
|  |         |                                                      |  |
|  |  +------+--------+                                             |  |
|  |  | Service LB    |  <--- Trafic externe (port 80/443)         |  |
|  |  | ingress-nginx |                                             |  |
|  |  +---------------+                                             |  |
|  +----------------------------------------------------------------+  |
|            |                                                         |
|            | Route selon les regles Ingress                          |
|            v                                                         |
|  Namespace: nginx                                                    |
|  +----------------------------------------------------------------+  |
|  |  +------------------+           +------------------+           |  |
|  |  | Service          |  -------> | Pod nginx        |           |  |
|  |  | nginx-service:80 |           | containerPort:80 |           |  |
|  |  +------------------+           +------------------+           |  |
|  +----------------------------------------------------------------+  |
|                                                                      |
+----------------------------------------------------------------------+
          ^
          |  app.example.com
          |
     +----------+
     |  Client  |
     |  (HTTP)  |
     +----------+
```

### Ingress Controller NGINX vs NGINX classique

Il ne faut pas confondre :
- **NGINX (le serveur web)** : c'est ce qu'on deploie dans les Pods comme serveur web (TP01)
- **NGINX Ingress Controller** : c'est un composant Kubernetes qui utilise NGINX comme reverse proxy pour router le trafic selon les regles Ingress

### Qu'est-ce qu'un IngressClass ?

Depuis Kubernetes 1.18, l'`IngressClass` permet de specifier quel Ingress Controller doit gerer une ressource Ingress donnee. Cela permet d'avoir plusieurs controllers dans le meme cluster (ex: NGINX pour le trafic public, Traefik pour le trafic interne).

### Qu'est-ce que Harbor ?

**Harbor** est un registre de conteneurs open-source developpe par VMware qui offre :
- **Stockage d'images Docker** prive (alternative a Docker Hub)
- **Scanner de vulnerabilites** integre (Trivy)
- **Signature d'images** (Notary/Cosign)
- **Replication** entre registres
- **RBAC** avec integration LDAP/OIDC
- **Quotas de stockage** par projet

## Objectifs

- Installer un Ingress Controller NGINX dans le cluster
- Comprendre le routage HTTP/HTTPS vers les services internes
- Deployer une ressource Ingress pour le service Nginx du TP01
- Installer Harbor comme registre de conteneurs prive

## Prerequis

- Un cluster Kubernetes fonctionnel (minikube, Docker Desktop, etc.)
- `kubectl` installe et configure
- `helm` installe (v3+)
- Le service `nginx-service` du TP01 deploye dans le namespace `nginx`

## Architecture deployee

```
Cluster Kubernetes
+-------------------------------------------------------------------+
|                                                                   |
|  Namespace: ingress-nginx                                         |
|  +-------------------------------------------------------------+ |
|  |  +-----------------------+   +---------------------------+   | |
|  |  | Pod NGINX Ingress     |   | Service LoadBalancer      |   | |
|  |  | Controller            |   | ingress-nginx-controller  |   | |
|  |  | (reverse proxy)       |   | port: 80, 443             |   | |
|  |  +-----------------------+   +---------------------------+   | |
|  +-------------------------------------------------------------+ |
|                    |                                              |
|     app.example.com --> route vers nginx-service:80               |
|                    |                                              |
|  Namespace: nginx                                                 |
|  +-------------------------------------------------------------+ |
|  |  +------------------+           +------------------+         | |
|  |  | Ingress          |           | Service          |         | |
|  |  | example-ingress  |           | nginx-service    |         | |
|  |  | host: app.       |  -------> | port: 80         |         | |
|  |  | example.com      |           +------------------+         | |
|  |  +------------------+                  |                     | |
|  |                                        v                     | |
|  |                                 +------------------+         | |
|  |                                 | Pod nginx        |         | |
|  |                                 +------------------+         | |
|  +-------------------------------------------------------------+ |
|                                                                   |
|  Namespace: harbor (optionnel)                                    |
|  +-------------------------------------------------------------+ |
|  |  Core, Registry, Portal, Trivy, JobService, Redis, DB       | |
|  +-------------------------------------------------------------+ |
+-------------------------------------------------------------------+
```

## Fichiers et explication detaillee

### `setup-ingress-nginx.sh` -- Script d'installation

```bash
#!/bin/bash
# Installation de l'Ingress Controller NGINX via Helm

helm upgrade --install ingress-nginx ingress-nginx \
  --repo https://kubernetes.github.io/ingress-nginx \
  --namespace ingress-nginx --create-namespace

echo "Verification du deploiement:"
kubectl get pods -n ingress-nginx
kubectl get svc -n ingress-nginx
```

**Explication des options :**
- `helm upgrade --install` : installe le chart s'il n'existe pas, ou le met a jour s'il existe deja. C'est une commande **idempotente**.
- `ingress-nginx ingress-nginx` : premier argument = nom de la release Helm, deuxieme = nom du chart.
- `--repo` : URL du depot Helm contenant le chart. Evite de devoir faire `helm repo add` avant.
- `--namespace ingress-nginx --create-namespace` : deploie dans le namespace `ingress-nginx`, le cree s'il n'existe pas.

### `ingress-example.yaml` -- Ressource Ingress

```yaml
apiVersion: networking.k8s.io/v1        # API Ingress standard Kubernetes
kind: Ingress
metadata:
  name: example-ingress                  # Nom de la ressource Ingress
  namespace: nginx                       # MEME namespace que le service cible
  annotations:
    nginx.ingress.kubernetes.io/rewrite-target: /    # Reecrit l'URL avant envoi au backend
spec:
  ingressClassName: nginx                # Quel Ingress Controller utiliser
  rules:
    - host: app.example.com              # Hostname pour le routage
      http:
        paths:
          - path: /                      # Chemin URL a matcher
            pathType: Prefix             # Type de correspondance
            backend:
              service:
                name: nginx-service      # Nom du service cible
                port:
                  number: 80             # Port du service cible
```

**Champs importants :**

- `apiVersion: networking.k8s.io/v1` : l'Ingress fait partie du groupe d'API `networking.k8s.io`, stabilise en v1 depuis Kubernetes 1.19.
- `metadata.namespace: nginx` : l'Ingress doit etre dans le **meme namespace** que le service qu'il cible. C'est une contrainte de securite : un Ingress ne peut pas router vers un service d'un autre namespace.
- `annotations.nginx.ingress.kubernetes.io/rewrite-target: /` : cette annotation est specifique au controller NGINX. Elle reecrit le chemin de la requete avant de l'envoyer au backend. Exemple : une requete vers `/app/page` sera reecrite en `/page`. Sans cette annotation, le chemin complet est transmis.
- `spec.ingressClassName: nginx` : specifie quel Ingress Controller doit traiter cet Ingress. Le controller NGINX cree automatiquement une IngressClass nommee `nginx` lors de son installation.
- `rules[].host: app.example.com` : le routage se fait par hostname. Le client doit envoyer une requete HTTP avec le header `Host: app.example.com`. Plusieurs `rules` avec des `host` differents permettent le routage multi-domaine.
- `pathType: Prefix` : `Prefix` matche tous les chemins commencant par `/` (donc tout le trafic). `Exact` ne matcherait que exactement `/`. `ImplementationSpecific` laisse le controller decider.
- `backend.service.name: nginx-service` : le service Kubernetes vers lequel router. Doit exister dans le meme namespace que l'Ingress.
- `backend.service.port.number: 80` : le port du service (le `port` du Service, pas le `targetPort`).

## Deploiement pas a pas

### 1. Installer l'Ingress Controller NGINX

```bash
chmod +x setup-ingress-nginx.sh
./setup-ingress-nginx.sh
```

Ou manuellement :

```bash
helm upgrade --install ingress-nginx ingress-nginx \
  --repo https://kubernetes.github.io/ingress-nginx \
  --namespace ingress-nginx --create-namespace
```

Sortie attendue :
```
Release "ingress-nginx" does not exist. Installing it now.
NAME: ingress-nginx
LAST DEPLOYED: ...
NAMESPACE: ingress-nginx
STATUS: deployed
REVISION: 1
```

### 2. Verifier l'installation

```bash
kubectl get pods -n ingress-nginx
```

Sortie attendue :
```
NAME                                        READY   STATUS    RESTARTS   AGE
ingress-nginx-controller-xxxxxxxxx-xxxxx    1/1     Running   0          60s
```

```bash
kubectl get svc -n ingress-nginx
```

Sortie attendue :
```
NAME                                 TYPE           CLUSTER-IP     EXTERNAL-IP   PORT(S)                      AGE
ingress-nginx-controller             LoadBalancer   10.96.xxx.xx   localhost      80:3xxxx/TCP,443:3xxxx/TCP   60s
ingress-nginx-controller-admission   ClusterIP      10.96.xxx.xx   <none>        443/TCP                      60s
```

### 3. S'assurer que le service cible existe

```bash
# Le service nginx du TP01 doit exister
kubectl get svc nginx-service -n nginx
```

Si le service n'existe pas, deployer d'abord le TP01 :
```bash
kubectl apply -f ../01-nginx/namespaces.yml
kubectl apply -f ../01-nginx/nginx.yml
kubectl apply -f ../01-nginx/service.yml
```

### 4. Appliquer l'Ingress

```bash
kubectl apply -f ingress-example.yaml
```

Sortie attendue :
```
ingress.networking.k8s.io/example-ingress created
```

```bash
kubectl get ingress -n nginx
```

Sortie attendue :
```
NAME              CLASS   HOSTS             ADDRESS     PORTS   AGE
example-ingress   nginx   app.example.com   localhost   80      30s
```

### 5. Tester le routage

**Sur Docker Desktop :**
```bash
# Ajouter l'entree dans /etc/hosts
echo "127.0.0.1 app.example.com" | sudo tee -a /etc/hosts

# Tester
curl http://app.example.com
```

**Sur minikube :**
```bash
# Activer l'addon ingress (alternative au chart Helm)
minikube addons enable ingress

# OU utiliser le tunnel
minikube tunnel

# Ajouter l'entree dans /etc/hosts
echo "$(minikube ip) app.example.com" | sudo tee -a /etc/hosts

# Tester
curl http://app.example.com
```

Sortie attendue :
```html
<!DOCTYPE html>
<html>
<head>
<title>Welcome to nginx!</title>
...
```

### 6. Installer Harbor (optionnel)

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

```bash
# Verifier l'installation
kubectl get pods -n harbor
```

Sortie attendue (apres quelques minutes) :
```
NAME                                    READY   STATUS    RESTARTS   AGE
harbor-core-xxxxxxxxx-xxxxx             1/1     Running   0          2m
harbor-database-0                       1/1     Running   0          2m
harbor-jobservice-xxxxxxxxx-xxxxx       1/1     Running   0          2m
harbor-portal-xxxxxxxxx-xxxxx           1/1     Running   0          2m
harbor-redis-0                          1/1     Running   0          2m
harbor-registry-xxxxxxxxx-xxxxx         2/2     Running   0          2m
harbor-trivy-0                          1/1     Running   0          2m
```

Acceder a Harbor : `https://harbor.example.com` (login par defaut : `admin` / `Harbor12345`).

## Routage avance : exemples supplementaires

### Routage multi-chemins

```yaml
spec:
  ingressClassName: nginx
  rules:
    - host: app.example.com
      http:
        paths:
          - path: /api
            pathType: Prefix
            backend:
              service:
                name: api-service
                port:
                  number: 8080
          - path: /
            pathType: Prefix
            backend:
              service:
                name: frontend-service
                port:
                  number: 80
```

### Routage multi-domaines

```yaml
spec:
  ingressClassName: nginx
  rules:
    - host: app.example.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: app-service
                port:
                  number: 80
    - host: api.example.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: api-service
                port:
                  number: 8080
```

### Terminaison TLS

```yaml
spec:
  ingressClassName: nginx
  tls:
    - hosts:
        - app.example.com
      secretName: app-tls-secret     # Secret contenant le certificat TLS
  rules:
    - host: app.example.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: app-service
                port:
                  number: 80
```

## Commandes utiles

```bash
# Lister les Ingress
kubectl get ingress -A

# Details d'un Ingress
kubectl describe ingress example-ingress -n nginx

# Voir les IngressClass disponibles
kubectl get ingressclass

# Logs du controller NGINX
kubectl logs -l app.kubernetes.io/name=ingress-nginx -n ingress-nginx

# Verifier la configuration NGINX generee
kubectl exec -n ingress-nginx deploy/ingress-nginx-controller -- cat /etc/nginx/nginx.conf

# Tester le routage avec curl et header Host
curl -H "Host: app.example.com" http://localhost
```

## Troubleshooting

### L'Ingress ne route pas le trafic (erreur 404)

**Cause probable** : le service cible n'existe pas ou n'est pas dans le meme namespace.
```bash
# Verifier que le service existe
kubectl get svc nginx-service -n nginx

# Verifier les endpoints du service
kubectl get endpoints nginx-service -n nginx
```
**Solution** : s'assurer que le service et l'Ingress sont dans le meme namespace et que le service a des endpoints (= des Pods avec les bons labels).

### L'EXTERNAL-IP du controller reste en `<pending>`

**Cause probable** : pas de load balancer disponible (minikube sans tunnel).
```bash
kubectl get svc -n ingress-nginx
```
**Solution** :
```bash
# minikube : lancer le tunnel
minikube tunnel

# Ou utiliser l'addon ingress de minikube
minikube addons enable ingress
```

### Erreur 503 Service Temporarily Unavailable

**Cause probable** : le service cible existe mais n'a pas d'endpoints (aucun Pod en Running).
```bash
kubectl get endpoints nginx-service -n nginx
# Si ENDPOINTS est <none>, aucun Pod ne correspond au selector
```
**Solution** : verifier que les Pods avec les bons labels sont en etat Running.

### L'annotation rewrite-target ne fonctionne pas

**Cause probable** : l'annotation est specifique a NGINX Ingress Controller et ne fonctionne pas avec d'autres controllers.
```bash
# Verifier l'IngressClass utilisee
kubectl get ingress example-ingress -n nginx -o yaml | grep ingressClassName
```

### Conflit entre plusieurs Ingress Controllers

**Cause probable** : plusieurs controllers installees, pas d'`ingressClassName` specifie.
```bash
kubectl get ingressclass
```
**Solution** : toujours specifier `ingressClassName` dans vos Ingress. Marquer un controller comme defaut :
```bash
kubectl annotate ingressclass nginx ingressclass.kubernetes.io/is-default-class=true
```

## Nettoyage

```bash
# Supprimer l'Ingress
kubectl delete -f ingress-example.yaml

# Supprimer le controller NGINX
helm uninstall ingress-nginx -n ingress-nginx
kubectl delete namespace ingress-nginx

# Supprimer Harbor (si installe)
helm uninstall harbor -n harbor
kubectl delete namespace harbor

# Nettoyer /etc/hosts
sudo sed -i '' '/app.example.com/d' /etc/hosts
```

## Pour aller plus loin

- [Documentation officielle Kubernetes : Ingress](https://kubernetes.io/docs/concepts/services-networking/ingress/)
- [Documentation NGINX Ingress Controller](https://kubernetes.github.io/ingress-nginx/)
- [Annotations NGINX Ingress Controller](https://kubernetes.github.io/ingress-nginx/user-guide/nginx-configuration/annotations/)
- [Documentation Harbor](https://goharbor.io/docs/)
- [cert-manager](https://cert-manager.io/) pour la gestion automatique des certificats TLS avec Let's Encrypt

**Suggestions d'amelioration :**
- Configurer cert-manager avec Let's Encrypt pour obtenir des certificats TLS automatiques
- Ajouter du rate limiting via les annotations NGINX (`nginx.ingress.kubernetes.io/limit-rps`)
- Configurer un default backend personnalise pour les erreurs 404
- Explorer Traefik comme Ingress Controller alternatif avec dashboard integre
- Configurer Harbor avec un stockage S3 pour la persistence des images

## QCM de revision

**Question 1** : Quelle est la difference entre une ressource Ingress et un Ingress Controller ?

- A) Il n'y a pas de difference, ce sont des synonymes
- B) L'Ingress definit les regles de routage, l'Ingress Controller est le composant qui les applique
- C) L'Ingress Controller est la ressource YAML et l'Ingress est le Pod
- D) L'Ingress est pour HTTP et l'Ingress Controller est pour TCP

<details>
<summary>Reponse</summary>
<b>B)</b> L'Ingress est une ressource declarative Kubernetes qui definit les regles de routage HTTP. L'Ingress Controller est le composant (generalement un reverse proxy comme NGINX) qui surveille ces ressources et configure le routage en consequence. Sans controller, les Ingress n'ont aucun effet.
</details>

---

**Question 2** : Pourquoi l'Ingress doit-il etre dans le meme namespace que le service cible ?

- A) C'est une limitation technique du reseau Kubernetes
- B) C'est une contrainte de securite : un Ingress ne peut referencer que les services de son namespace
- C) Ce n'est pas obligatoire, c'est juste une bonne pratique
- D) L'Ingress Controller ne peut lire que les Ingress de son propre namespace

<details>
<summary>Reponse</summary>
<b>B)</b> C'est une contrainte de securite deliberee. Un Ingress dans le namespace A ne peut pas router vers un service du namespace B. Cela evite qu'un utilisateur ayant acces a un namespace puisse detourner le trafic vers des services d'autres namespaces.
</details>

---

**Question 3** : Quel est l'avantage principal d'utiliser un Ingress plutot que des Services LoadBalancer multiples ?

- A) L'Ingress est plus rapide que les LoadBalancers
- B) Un seul point d'entree (et un seul LoadBalancer) pour router vers plusieurs services, avec routage par hostname/path
- C) L'Ingress supporte le protocole UDP contrairement aux LoadBalancers
- D) L'Ingress ne necessite pas de DNS

<details>
<summary>Reponse</summary>
<b>B)</b> L'Ingress permet d'avoir un seul LoadBalancer (= un seul cout, une seule IP publique) devant l'Ingress Controller, qui route le trafic vers differents services en fonction du hostname ou du chemin URL. Avec des LoadBalancers multiples, chaque service necessite son propre LB.
</details>

---

**Question 4** : Que fait l'annotation `nginx.ingress.kubernetes.io/rewrite-target: /` ?

- A) Elle redirige (HTTP 301) le client vers /
- B) Elle reecrit le chemin de la requete en / avant de l'envoyer au backend
- C) Elle force l'utilisation de HTTPS
- D) Elle configure le chemin par defaut du serveur NGINX

<details>
<summary>Reponse</summary>
<b>B)</b> L'annotation <code>rewrite-target</code> modifie le chemin de la requete HTTP avant de la transmettre au service backend. Avec <code>rewrite-target: /</code>, une requete vers <code>/app/page</code> sera transmise au backend comme <code>/page</code> (le prefixe est supprime). Ce n'est pas une redirection HTTP visible par le client.
</details>

---

**Question 5** : A quoi sert le champ `ingressClassName: nginx` ?

- A) Il nomme la ressource Ingress
- B) Il specifie quel Ingress Controller doit traiter cet Ingress
- C) Il configure le type de serveur web utilise par le backend
- D) Il definit la classe CSS pour l'interface web

<details>
<summary>Reponse</summary>
<b>B)</b> Le champ <code>ingressClassName</code> indique quel Ingress Controller doit traiter cette ressource Ingress. Cela permet d'avoir plusieurs controllers dans le meme cluster (ex: NGINX pour le trafic public, Traefik pour le trafic interne) et de choisir lequel utiliser pour chaque Ingress.
</details>

---

**Question 6** : Quelle est la difference entre `pathType: Prefix` et `pathType: Exact` ?

- A) `Prefix` est plus performant qu'`Exact`
- B) `Prefix` matche tous les chemins commencant par le path donne, `Exact` ne matche que le chemin exact
- C) `Prefix` est pour HTTP et `Exact` est pour HTTPS
- D) Il n'y a pas de difference fonctionnelle

<details>
<summary>Reponse</summary>
<b>B)</b> Avec <code>pathType: Prefix</code> et <code>path: /api</code>, les requetes vers <code>/api</code>, <code>/api/users</code>, <code>/api/v1/data</code> sont toutes matchees. Avec <code>pathType: Exact</code>, seule <code>/api</code> exactement est matchee. <code>/api/</code> ou <code>/api/users</code> ne le seraient pas.
</details>

---

**Question 7** : Quel composant Harbor est responsable de l'analyse des vulnerabilites des images ?

- A) harbor-core
- B) harbor-registry
- C) harbor-trivy
- D) harbor-jobservice

<details>
<summary>Reponse</summary>
<b>C)</b> <code>harbor-trivy</code> est le scanner de vulnerabilites integre a Harbor. Trivy (developpe par Aqua Security) analyse les images Docker a la recherche de vulnerabilites connues (CVE) dans les packages OS et les dependances applicatives.
</details>
