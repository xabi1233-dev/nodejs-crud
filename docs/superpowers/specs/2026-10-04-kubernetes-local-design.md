# Running the CRUD app on local Kubernetes

**Date:** 2026-10-04
**Status:** Approved design, not yet implemented
**Scope:** Local laptop cluster only. Nothing in `infra/`, `deploy/` or
`.github/workflows/` changes. The EC2 production stack is untouched.

---

## 1. Purpose

Learn Kubernetes by running this app's real workload on a real cluster,
with manifests faithful enough to explain to someone else: Deployments,
Services, StatefulSets, PersistentVolumeClaims, Secrets, ConfigMaps,
Ingress, and health probes.

Explicit non-goals:

- **No cloud cluster.** EKS costs ~$105-135/month once you count the
  control plane, workers, a load balancer and NAT. Rejected on cost.
- **No change to production.** The EC2 instance keeps running Docker
  Compose behind nginx exactly as it does today.
- **No CI integration.** The GitHub Actions workflows are not touched.
- **No Helm.** Raw manifests first; packaging is a separate exercise.

Success means all three verification tests in section 9 pass.

---

## 2. Starting conditions

Measured on 2026-10-04, not assumed:

| Fact | Value | Consequence |
|---|---|---|
| Cluster | Docker Desktop, `docker-desktop` context | Already running. Nothing to install. |
| Kubernetes server | v1.36.1, single node, `Ready` | — |
| kubectl client | v1.35.9 | One minor behind server; inside the supported ±1 skew. |
| Node allocatable | 3 761 244 Ki (~3.6 Gi), 8 CPU | Docker Desktop's VM cap, **not** the laptop's 15 Gi. Resource limits are load-bearing. |
| Default StorageClass | `hostpath (default)`, provisioner `docker.io/hostpath` | PVCs bind automatically; no provisioner setup needed. |
| Reclaim policy | `Delete`, `allowVolumeExpansion: false` | Deleting the PVC destroys the data. Volumes cannot be grown later. |
| Ingress controllers | none | We install one. |
| Host port 80 | held by Apache (`active`) | **Conflict.** See decision 5. |
| `/etc/hosts` | `127.0.0.1 crud.local` → Apache vhost | Cannot reuse that hostname. |
| Disk free | 41 GB (91 % used) | `mysql:8.4` + ingress-nginx ≈ 700 MB. Fits, but not flush. |
| metrics-server | not installed | `kubectl top` will not work. Out of scope. |

---

## 3. Architecture

```
browser   http://crud.k8s.local:8080
   │
   ▼
ingress-nginx                     Service type LoadBalancer, port 8080
   │                              (NOT 80 — Apache holds it)
   │  Ingress rule: host crud.k8s.local  →  crud-app:3000
   ▼
Service crud-app                  ClusterIP :3000
   │                              load-balances across both replicas
   ▼
Deployment crud-app               replicas: 2
   │                              image crud-app:k8s, imagePullPolicy: Never
   │                              readinessProbe  GET /health   (deep, SELECT 1)
   │                              livenessProbe   GET /livez    (shallow)
   │                              env ← Secret crud-db-secret
   │                              DB_HOST = crud-db-0.crud-db
   ▼
Service crud-db                   headless (clusterIP: None)
   │
   ▼
StatefulSet crud-db               replicas: 1, image mysql:8.4 (stock)
                                  ConfigMap crud-db-schema
                                    → /docker-entrypoint-initdb.d/
                                  volumeClaimTemplate → 2Gi, hostpath
```

All objects live in namespace `crud`.

---

## 4. Design decisions

### 4.1 StatefulSet for MySQL, not Deployment

A Deployment backed by a `ReadWriteOnce` PVC deadlocks on rolling
update: the replacement pod cannot mount the volume while the outgoing
pod still holds it, and the outgoing pod is not terminated until the
replacement is Ready. The rollout hangs indefinitely.

A StatefulSet avoids this structurally — it terminates before it
creates — and additionally gives a stable pod identity (`crud-db-0`)
and per-replica storage via `volumeClaimTemplates`.

Rejected alternative: Deployment with `strategy: Recreate`. It works,
but it teaches the wrong default and still has no stable DNS name.

### 4.2 ConfigMap for the schema, not the baked `crud-db` image

`docker/mysql.Dockerfile` exists for one reason: Docker Desktop only
shares certain host paths with its VM, and a bind mount from
`/var/www` silently appears as an **empty directory**, so
`schema.sql` could not be mounted into `/docker-entrypoint-initdb.d/`.
Baking it into an image was the workaround.

ConfigMaps do not touch host paths at all, so that constraint does not
exist in Kubernetes. Using stock `mysql:8.4` plus a ConfigMap means one
fewer image to build, and a schema change no longer requires a rebuild.

This is a deliberate divergence from the Compose stack. The Compose
stack keeps its baked image; it still needs it.

**Generation, not transcription.** The ConfigMap is produced *from*
`schema.sql` so the two cannot drift:

```
kubectl create configmap crud-db-schema \
  --from-file=schema.sql \
  -n crud --dry-run=client -o yaml > k8s/11-configmap-schema.yaml
```

That command is recorded in `k8s/README.md` as the way to regenerate
it. The generated YAML is committed.

**On the contents being verbatim.** `schema.sql` carries three
statements aimed at the old bare-metal install:

```sql
CREATE DATABASE IF NOT EXISTS crud_db ...;
CREATE USER IF NOT EXISTS 'crud_user'@'localhost' IDENTIFIED BY 'CHANGE_ME_StrongPass#1';
GRANT ALL PRIVILEGES ON crud_db.* TO 'crud_user'@'localhost';
```

All three are inert in a container. The MySQL entrypoint processes
`MYSQL_DATABASE` / `MYSQL_USER` / `MYSQL_PASSWORD` *before* it runs
`/docker-entrypoint-initdb.d/`, so the database already exists and the
working account is `crud_user@'%'`. The `@'localhost'` account created
here can never match a TCP connection from another pod, and
`CHANGE_ME_StrongPass#1` is therefore never a usable credential.

These statements already run, harmlessly, in the existing Compose
stack. Carrying them verbatim is preferred over hand-trimming a second
copy of the schema, because a single source of truth is worth more than
cosmetic tidiness. Removing them from `schema.sql` is a reasonable
separate change; it is **out of scope here** because it would also touch
the Compose and bare-metal paths.

### 4.3 `imagePullPolicy: Never` with an explicit tag

Docker Desktop's Kubernetes shares the Docker daemon's image store, so
an image built locally is immediately visible to the cluster. No
registry, no ECR, no GHCR:

```
docker build -t crud-app:k8s .
```

`imagePullPolicy: Never` is required — the default would try to pull
`crud-app:k8s` from Docker Hub and fail with `ErrImagePull`.

The tag must be explicit, never `:latest`. `Never` plus `:latest` is a
known footgun: the cluster silently keeps running whatever `:latest`
pointed at when the pod started, so a rebuild appears to do nothing.

**Consequence to document:** after any `docker build`, the pods must be
restarted to pick the new image up:

```
kubectl rollout restart deployment/crud-app -n crud
```

### 4.4 Liveness must not use `/health`

`/health` executes `SELECT 1` against MySQL (`server.js:146-149`). It is
a *deep* check and correct as a **readiness** probe — when the database
is unreachable the pod should stop receiving traffic.

Using it as a **liveness** probe would be actively harmful. A MySQL
blip would make the kubelet kill every app pod, repeatedly, in a
restart loop that cannot fix a database problem and that removes the
application on top of it.

So the app gains a shallow endpoint:

```js
// Liveness, not health: answers "is this process still serving?" and
// deliberately does NOT touch the database. A deep check here would let
// a MySQL blip trigger an endless pod-restart loop that cannot help.
app.get('/livez', (req, res) => res.json({ ok: true }));
```

Placed **before** the 404 catch-all at `server.js:153`.

| Probe | Path | Checks |
|---|---|---|
| readiness | `/health` | process **and** database |
| liveness | `/livez` | process only |

Rejected alternative: a `tcpSocket` liveness probe. It needs no code
change, but it only proves a socket is bound, not that the event loop
is still turning. Three lines is a fair price for a real answer.

### 4.5 Port 8080 and the hostname `crud.k8s.local`

Apache is running and holds `*:80`, and `/etc/hosts:14` already maps
`crud.local` to it. Two ways out:

1. Stop Apache. Frees port 80, breaks the existing `crud.local` vhost
   and anything else Apache serves.
2. Give the cluster its own hostname on its own port.

Option 2 is chosen. It disrupts nothing, and it leaves both versions
running at once — the Apache/Compose deployment on `crud.local` and
the Kubernetes deployment on `crud.k8s.local:8080` — so they can be
compared side by side.

Requires one line added to `/etc/hosts`:

```
127.0.0.1 crud.k8s.local
```

**Ingress controller installation.** Install ingress-nginx from its
official static manifest for the `cloud` provider, then patch the
controller Service's port from 80 to 8080. Docker Desktop fulfils
`LoadBalancer` services by binding the service port on localhost, so
this yields `http://crud.k8s.local:8080`.

The controller version must be pinned to an explicit release tag —
never `main` — selected at implementation time from the ingress-nginx
compatibility table for Kubernetes 1.36.

**Contingency, with its trigger.** If after patching, `ss -ltn` does
not show 8080 bound, switch the controller Service to `type: NodePort`
with `nodePort: 30080` and use `http://crud.k8s.local:30080`. Docker
Desktop's node is localhost, so NodePorts are reachable directly. The
default NodePort range is 30000-32767, which is why the fallback port
is 30080 and not 8080.

### 4.6 Secrets are encoding, not encryption

A Kubernetes Secret is base64. Anyone who can read the YAML has the
password. This mirrors the existing `.env` discipline:

| File | Tracked? | Contents |
|---|---|---|
| `k8s/secret.example.yaml` | yes | placeholders only |
| `k8s/secret.yaml` | **no** — gitignored | real generated passwords |

The real Secret is generated, never hand-edited:

```
kubectl create secret generic crud-db-secret -n crud \
  --from-literal=MYSQL_ROOT_PASSWORD="$(openssl rand -base64 24 | tr -d '/+=' | cut -c1-24)" \
  --from-literal=MYSQL_PASSWORD="$(openssl rand -base64 24 | tr -d '/+=' | cut -c1-24)" \
  --dry-run=client -o yaml > k8s/secret.yaml
```

Both the MySQL pod and the app pod consume it. The same `MYSQL_PASSWORD`
key is surfaced to the app as `DB_PASSWORD` via `secretKeyRef`, so the
value exists in exactly one place.

`.gitignore` gains `k8s/secret.yaml`. This must be committed **before**
the secret is generated, so the file is never momentarily trackable.

### 4.7 Resource requests and limits are mandatory

The VM has ~3.6 Gi allocatable, not the laptop's 15 Gi. Without limits
one pod can starve the control plane and take the whole cluster down.

| Workload | Request | Limit |
|---|---|---|
| `crud-db` | 512Mi / 250m | 1Gi / 1000m |
| `crud-app` ×2 | 128Mi / 100m each | 256Mi / 500m each |
| ingress-nginx | ~100Mi (its own default) | — |
| control plane | ~800Mi (observed) | — |
| **Total requests** | **≈1.6 Gi of 3.6 Gi** (512+128+128+100+800 = 1 668Mi) | headroom ≈2.0 Gi |

Two app replicas rather than one: a Service load-balancing to a single
pod demonstrates nothing, and a rolling update with one replica has no
surviving pod to serve traffic. The second replica costs 128Mi and
makes verification test 3 meaningful.

---

## 5. Data flow

**Startup, first ever run:**

1. `crud-db-0` starts. The PVC is empty, so the MySQL entrypoint
   initialises the data directory.
2. The entrypoint reads `MYSQL_ROOT_PASSWORD`, `MYSQL_DATABASE`,
   `MYSQL_USER`, `MYSQL_PASSWORD` from the Secret and the pod spec, and
   creates the database and the `crud_user@'%'` account.
3. The entrypoint then runs `/docker-entrypoint-initdb.d/schema.sql`
   from the mounted ConfigMap, creating the `users` table and the three
   seed rows.
4. `crud-app` pods start. Their readiness probe fails while MySQL is
   still initialising, so the Service sends them no traffic.
5. MySQL accepts connections. `/health` returns 200. The pods become
   Ready and enter the Service's endpoint list.

**Startup, every subsequent run:** the PVC is non-empty, so the
entrypoint skips both initialisation and the initdb.d scripts
entirely. Existing rows persist. This is what verification test 2
proves.

**Request path:** browser → `crud.k8s.local:8080` → ingress-nginx →
host-rule match → `crud-app` Service → one of two pods → `mysql2` pool
→ `crud-db-0.crud-db:3306`.

---

## 6. Failure modes

| Failure | Behaviour | Where it surfaces |
|---|---|---|
| MySQL pod down | App readiness fails; Service drops both pods; ingress returns 503. App pods are **not** killed (decision 4.4). | `kubectl get pods`, ingress 503 |
| One app pod dies | Service routes to the survivor. No visible downtime. | Verification test 3 |
| Image rebuilt, pods not restarted | Old code keeps running, silently. | Mitigated by documenting `rollout restart` in the README (decision 4.3) |
| Node memory pressure | Pod exceeding its limit is OOMKilled and restarted. | `kubectl describe pod`, `OOMKilled` |
| PVC deleted | **Data destroyed permanently.** Reclaim policy is `Delete`. | Stated in the README as a warning |
| Secret missing | Pods stay `CreateContainerConfigError`. | `kubectl describe pod` |
| Port 8080 also taken | Ingress Service stays `<pending>`. | Contingency in decision 4.5 |

---

## 7. Files

New:

```
k8s/
  00-namespace.yaml            namespace crud
  10-secret.example.yaml       placeholders, tracked
  11-configmap-schema.yaml     generated from schema.sql
  20-mysql-statefulset.yaml    + volumeClaimTemplate 2Gi
  21-mysql-service.yaml        headless, clusterIP: None
  30-app-deployment.yaml       2 replicas, probes, limits
  31-app-service.yaml          ClusterIP :3000
  40-ingress.yaml              host crud.k8s.local
  README.md                    runbook
```

Generated, never committed:

```
k8s/secret.yaml
```

Modified:

| File | Change |
|---|---|
| `server.js` | add `/livez` before the 404 handler |
| `.gitignore` | add `k8s/secret.yaml` |
| `.dockerignore` | add `k8s/` and `docs/` |

Unchanged, and deliberately so: everything in `infra/`, `deploy/`,
`.github/workflows/`, `docker-compose.yml`, `Dockerfile`,
`docker/mysql.Dockerfile`, `schema.sql`.

The numeric filename prefixes make `kubectl apply -f k8s/` apply them in
dependency order — namespace before the objects inside it, Secret and
ConfigMap before the workloads that mount them.

---

## 8. Host-level prerequisites

Two changes outside the repo, both needing `sudo`, both to be run by the
user rather than by an automated script:

1. `/etc/hosts` gains `127.0.0.1 crud.k8s.local`
2. Nothing else. Apache keeps running; port 80 is not touched.

---

## 9. Verification

Pod status is not evidence. Three tests, each proving one decision:

**Test 1 — it serves.** Proves ingress, Service routing, and the app's
database connection.

```
curl -s http://crud.k8s.local:8080/health
# expect: {"ok":true,"db":"up"}
curl -s http://crud.k8s.local:8080/ | grep -c "Ada Lovelace"
# expect: 1
```

**Test 2 — storage survives.** The only test that justifies the
StatefulSet and the PVC. Add a row through the UI at
`http://crud.k8s.local:8080/` with the distinctive name
`Persistence Probe`, then:

```
kubectl delete pod crud-db-0 -n crud
kubectl wait --for=condition=ready pod/crud-db-0 -n crud --timeout=120s
curl -s http://crud.k8s.local:8080/ | grep -c "Persistence Probe"
# expect: 1   — the row survived the pod being destroyed
```

`0` means the database came back seed-only, i.e. the PVC is not
retaining data and the StatefulSet is giving no more than a Deployment
with `emptyDir` would.

**Test 3 — replicas survive.** Proves the Deployment and the Service
load-balancer.

```
kubectl delete pod -l app=crud-app -n crud --wait=false
for i in $(seq 1 20); do
  curl -s -o /dev/null -w '%{http_code} ' http://crud.k8s.local:8080/health
  sleep 1
done
# expect: 200 throughout — the surviving replica serves while the other restarts
```

---

## 10. Out of scope

Named so they are choices rather than oversights:

- metrics-server / `kubectl top`
- HorizontalPodAutoscaler — nothing here autoscales meaningfully
- NetworkPolicy
- TLS on the ingress — HTTP is sufficient locally; production already
  has real Let's Encrypt certificates
- Helm packaging
- Applying these manifests in CI
- Removing the dead `@'localhost'` statements from `schema.sql`
  (decision 4.2)
- Any change to the EC2 production stack
