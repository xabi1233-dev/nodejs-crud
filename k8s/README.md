# Running this app on local Kubernetes

Laptop only. This changes nothing about the EC2 production deployment, which
still runs Docker Compose behind nginx.

Design and rationale:
[`../docs/superpowers/specs/2026-10-04-kubernetes-local-design.md`](../docs/superpowers/specs/2026-10-04-kubernetes-local-design.md)

## Prerequisites

- Docker Desktop with Kubernetes enabled (`kubectl config use-context docker-desktop`)
- `127.0.0.1 crud.k8s.local` in `/etc/hosts`
- Traefik installed (see "First-time setup")

## Everyday use

```bash
docker build -t crud-app:k8s .
kubectl apply -f k8s/
kubectl get pods -n crud -w
```

Then open <http://crud.k8s.local:8080>

## After changing application code

`imagePullPolicy: Never` means the pods keep running the **old** image until
they are restarted. Rebuilding alone does nothing:

```bash
docker build -t crud-app:k8s .
kubectl rollout restart deployment/crud-app -n crud
kubectl rollout status deployment/crud-app -n crud
```

If a change does not appear, this is almost always why.

## After changing schema.sql

Regenerate the ConfigMap — never edit the generated file by hand:

```bash
kubectl create configmap crud-db-schema --from-file=schema.sql \
  -n crud --dry-run=client -o yaml > k8s/11-configmap-schema.yaml
kubectl apply -f k8s/11-configmap-schema.yaml
```

This only affects a **fresh** database. The MySQL entrypoint runs
`/docker-entrypoint-initdb.d` only when the data directory is empty, so an
existing PVC ignores the new schema entirely.

## First-time setup

```bash
# 1. Traefik. (ingress-nginx was retired 2026-03-24 — no security patches.)
helm repo add traefik https://traefik.github.io/charts
helm repo update
helm install traefik traefik/traefik \
  --namespace traefik --create-namespace \
  --set ports.web.exposedPort=8080 \
  --set ports.websecure.expose.default=false

# 2. Hostname
echo "127.0.0.1 crud.k8s.local" | sudo tee -a /etc/hosts

# 3. Namespace and the Secret (gitignored, never hand-edited)
kubectl apply -f k8s/00-namespace.yaml
kubectl create secret generic crud-db-secret -n crud \
  --from-literal=MYSQL_ROOT_PASSWORD="$(openssl rand -base64 24 | tr -d '/+=' | cut -c1-24)" \
  --from-literal=MYSQL_PASSWORD="$(openssl rand -base64 24 | tr -d '/+=' | cut -c1-24)" \
  --dry-run=client -o yaml > k8s/secret.yaml

# 4. Everything else
docker build -t crud-app:k8s .
kubectl apply -f k8s/
```

Port 8080, not 80, because Apache holds 80 on this laptop and already serves
the Compose version of this app at `crud.local`. The two run side by side.

## Teardown

```bash
# Stop the workloads, KEEP the database
kubectl delete -f k8s/30-app-deployment.yaml -f k8s/20-mysql-statefulset.yaml

# Remove everything INCLUDING the database, permanently
kubectl delete namespace crud
```

> **The PVC is where your data lives.** The `hostpath` StorageClass has reclaim
> policy `Delete`, so deleting the PVC — or the namespace containing it —
> destroys the rows with no recovery. Deleting the *pod* is safe: that is what
> acceptance test 2 proves.

## Troubleshooting

| Symptom | Cause |
|---|---|
| `ErrImagePull` on `crud-app:k8s` | Image not built locally, or `imagePullPolicy` is not `Never` |
| Code change has no effect | Pods still running the old image — `kubectl rollout restart` |
| `CreateContainerConfigError` | Secret missing or a key misspelled. `kubectl logs` is empty; use `kubectl describe pod` |
| App pods `Running 0/1`, no endpoints | Readiness failing — MySQL is down. Working as designed |
| 404 from `localhost:8080` | Traefik routes on the `Host` header. Use `crud.k8s.local:8080` |
| `crud-db-0` PVC `Pending` | No default StorageClass |
| Traefik `EXTERNAL-IP <pending>` | Port 8080 already taken; see spec §4.5 NodePort contingency |
| `nslookup` says NXDOMAIN for `crud-db-0.crud-db` | busybox `nslookup` mishandles Kubernetes search paths. Use `getent hosts` from a glibc image |

## What this does NOT cover

metrics-server (`kubectl top`), HorizontalPodAutoscaler, NetworkPolicy, TLS,
Helm packaging of this app, and CI. See spec §10.
