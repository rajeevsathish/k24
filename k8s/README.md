# Keycloak 24.0.4 — 3-Node Cluster on Minikube

## Prerequisites

| Tool | Minimum version |
|------|----------------|
| minikube | 1.30+ |
| kubectl | 1.27+ |
| docker | 24+ (used as minikube driver) |

## Architecture

```
                    ┌──────────────┐
                    │   Ingress    │  keycloak.local
                    │  (nginx)     │
                    └──────┬───────┘
                           │
              ┌────────────┼────────────┐
              │            │            │
        ┌─────┴────┐ ┌────┴─────┐ ┌────┴─────┐
        │keycloak-0│ │keycloak-1│ │keycloak-2│   StatefulSet (3 replicas)
        └─────┬────┘ └────┬─────┘ └────┬─────┘
              │   JGroups  │  DNS_PING  │         Infinispan cluster
              │  ←────────→│←──────────→│
              └────────────┼────────────┘
                           │
                    ┌──────┴───────┐
                    │  PostgreSQL  │   Shared DB
                    │  (single)    │
                    └──────────────┘
```

**Clustering mechanism:**
- **Infinispan** handles distributed caching (sessions, auth sessions, action tokens).
- **JGroups DNS_PING** discovers peer pods via the headless Service DNS (`keycloak-headless`).
- Distributed caches use `owners="2"` — each session is replicated to 2 of the 3 nodes.
- Sticky sessions via Ingress `KC_ROUTE` cookie ensure users hit the same pod.

## Quick Start

```bash
cd keycloak_local_setup/keycloak-24.0.4
bash k8s/deploy.sh
```

The script will:
1. Start Minikube (4 CPUs, 6 GB RAM)
2. Enable the NGINX Ingress addon
3. Copy themes, providers, and realm JSON into the Minikube VM
4. Apply all Kubernetes manifests in order
5. Wait for pods to be ready and print access instructions

## Manual Step-by-Step

### 1. Start Minikube

```bash
minikube start --cpus=4 --memory=6144 --driver=docker
minikube addons enable ingress
```

### 2. Copy files into Minikube

```bash
minikube ssh -- "sudo mkdir -p /data/keycloak/{themes,providers,realm}"

minikube cp themes/sunbird /data/keycloak/themes/sunbird
minikube cp providers/keycloak-email-phone-autthenticator-1.0-SNAPSHOT.jar \
  /data/keycloak/providers/keycloak-email-phone-autthenticator-1.0-SNAPSHOT.jar
minikube cp realm/sunbird-realm.json /data/keycloak/realm/sunbird-realm.json
```

### 3. Deploy

```bash
kubectl apply -f k8s/00-namespace.yaml
kubectl apply -f k8s/01-postgres.yaml
kubectl -n keycloak rollout status deployment/postgres --timeout=120s

kubectl apply -f k8s/02-keycloak-config.yaml
kubectl apply -f k8s/03-keycloak-statefulset.yaml
kubectl apply -f k8s/04-ingress.yaml
kubectl -n keycloak rollout status statefulset/keycloak --timeout=300s
```

### 4. Configure /etc/hosts

```bash
echo "$(minikube ip)  keycloak.local" | sudo tee -a /etc/hosts
```

### 5. Access Keycloak

- **URL:** http://keycloak.local
- **Admin Console:** http://keycloak.local/admin
- **Username:** `admin`
- **Password:** `sunbird`

## Verify Cluster Formation

```bash
# Check all 3 pods are Running
kubectl -n keycloak get pods

# Verify Infinispan cluster size (should show 3 members)
kubectl -n keycloak logs keycloak-0 | grep -i "members"

# Check pod IPs match the headless service
kubectl -n keycloak get endpoints keycloak-headless
```

Expected log line:
```
Received new cluster view: [keycloak-0-xxxxx|2] (3) [keycloak-0-..., keycloak-1-..., keycloak-2-...]
```

## Useful Commands

```bash
# Scale up/down
kubectl -n keycloak scale statefulset keycloak --replicas=5

# View logs for a specific pod
kubectl -n keycloak logs -f keycloak-1

# Port-forward directly to a pod (bypass ingress)
kubectl -n keycloak port-forward keycloak-0 8080:8080

# Restart all Keycloak pods (rolling)
kubectl -n keycloak rollout restart statefulset/keycloak

# Delete everything
kubectl delete namespace keycloak
```

## Manifest Files

| File | Description |
|------|-------------|
| `k8s/00-namespace.yaml` | `keycloak` namespace |
| `k8s/01-postgres.yaml` | PostgreSQL 15.14 Deployment + PVC + Service |
| `k8s/02-keycloak-config.yaml` | Secrets, ConfigMap, Infinispan cache XML |
| `k8s/03-keycloak-statefulset.yaml` | Keycloak StatefulSet (3 replicas), headless Service, RBAC |
| `k8s/04-ingress.yaml` | NGINX Ingress with sticky sessions |
| `k8s/deploy.sh` | One-click deployment script |

## Troubleshooting

**Pods stuck in CrashLoopBackOff:**
```bash
kubectl -n keycloak describe pod keycloak-0
kubectl -n keycloak logs keycloak-0 --previous
```

**Cluster not forming (only 1 member):**
- Verify the headless service resolves all pod IPs:
  ```bash
  kubectl -n keycloak run dns-test --rm -it --image=busybox -- nslookup keycloak-headless.keycloak.svc.cluster.local
  ```
- Check JGroups port 7800 is not blocked.

**Realm not imported:**
- Import only happens on first startup. To re-import:
  ```bash
  kubectl -n keycloak delete statefulset keycloak
  # clear the PG database or drop/recreate the keycloakdb
  kubectl apply -f k8s/03-keycloak-statefulset.yaml
  ```

## Production Considerations

> These manifests are for **local development on Minikube**. For production:
> - Use a managed PostgreSQL (RDS, Cloud SQL, etc.)
> - Replace `hostPath` volumes with proper PVCs or a container image with themes baked in
> - Enable TLS termination at the Ingress
> - Set `KC_HOSTNAME` to the real domain
> - Use Kubernetes Secrets backed by a vault (e.g., HashiCorp Vault, AWS Secrets Manager)
> - Increase resource requests/limits based on load testing
