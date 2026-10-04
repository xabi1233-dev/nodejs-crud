# Local Kubernetes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Run the existing CRUD app on the laptop's Docker Desktop
Kubernetes cluster using faithful manifests — Deployment, Service,
StatefulSet, PersistentVolumeClaim, Secret, ConfigMap, Ingress and
health probes — without touching the EC2 production stack.

**Architecture:** Traefik terminates HTTP on `crud.k8s.local:8080` and
routes to a 2-replica `crud-app` Deployment behind a ClusterIP Service.
The app reaches MySQL at `crud-db-0.crud-db`, a single-replica
StatefulSet with a 2Gi PVC, seeded on first boot from a ConfigMap
generated out of `schema.sql`. Credentials live in one Secret consumed
by both workloads. The app image is built locally and consumed directly
from the Docker image store — no registry.

**Tech Stack:** Kubernetes 1.36.1 (Docker Desktop), kubectl 1.35.9,
Helm (to be installed), Traefik, MySQL 8.4, Node 22, Express.

**Spec:** [`docs/superpowers/specs/2026-10-04-kubernetes-local-design.md`](../specs/2026-10-04-kubernetes-local-design.md)

---

## Execution note

Every command in this plan runs on the **laptop**. There is no server
step anywhere in this plan. Commands are marked `[LAPTOP]` and are meant
to be run one stage at a time, reading the output before moving on.

Three commands need `sudo` and are called out where they appear: the
Helm install, and the `/etc/hosts` edit.

**Working directory for every command:** `/var/www/your_domain/crud`

---

## Global Constraints

Copied from the spec. Every task's requirements implicitly include these.

- **Laptop only.** These files must not change: `infra/`, `deploy/`,
  `.github/workflows/`, `docker-compose.yml`, `Dockerfile`,
  `docker/mysql.Dockerfile`, `schema.sql`. Production is untouched.
- **Namespace:** every object lives in `crud`.
- **Image tag:** exactly `crud-app:k8s` with `imagePullPolicy: Never`.
  Never `:latest` — `Never` plus `:latest` silently runs a stale image.
- **Resource limits are mandatory** on every workload. Node allocatable
  is 3 761 244 Ki (~3.6 Gi), not the laptop's 15 Gi.
- **`k8s/secret.yaml` is never committed.** Its `.gitignore` entry is
  committed *before* the file is generated.
- **Probes:** readiness uses `/health` (deep, hits MySQL), liveness uses
  `/livez` (shallow). Never the reverse — see spec §4.4.
- **Ingress:** `ingressClassName: traefik`, host `crud.k8s.local`,
  reached on port **8080** (Apache holds 80).
- **Storage:** default `hostpath` StorageClass, reclaim policy `Delete`,
  `allowVolumeExpansion: false`. Deleting a PVC destroys the data.
- **Version skew:** kubectl 1.35.9 against server 1.36.1 — one minor,
  inside the supported ±1. Do not "fix" this.
- No test framework exists in this project (ESLint only). Verification
  is `kubectl` and `curl` assertions, which is the correct test cycle
  for manifest work. Do not add Jest/Mocha.

---

## Review Focus

Five failure modes the spec implies that are most likely to bite,
most likely first. Each has a test pinned to the task that owns it.

1. **MySQL's first-boot init takes 60-90 s.** A readiness probe with a
   short `failureThreshold` marks the pod failed and restarts it mid-init,
   forever. → tested in Task 3, Step 7.
2. **App pods start before MySQL accepts connections.** Readiness must
   fail and hold traffic back; the pod must *not* crash-loop, because
   `mysql2` pools lazily and the process stays up. → Task 4, Step 8.
3. **A rebuilt image is silently ignored.** `imagePullPolicy: Never`
   means a `docker build` changes nothing until the pods are restarted.
   → Task 6, Step 4.
4. **A missing or mis-keyed Secret** leaves pods in
   `CreateContainerConfigError`, not `CrashLoopBackOff` — a different
   symptom that sends people debugging the wrong thing. → Task 2, Step 9.
5. **Requesting by `localhost` instead of `crud.k8s.local` returns 404.**
   Traefik matches on the `Host` header, so the right app on the right
   port still 404s under the wrong hostname. This is the same class of
   confusion as the certbot `server_name` 404 on EC2. → Task 5, Step 9.

---

## File Structure

| File | Responsibility |
|---|---|
| `k8s/00-namespace.yaml` | the `crud` namespace, nothing else |
| `k8s/secret.yaml.example` | tracked template, placeholders only |
| `k8s/secret.yaml` | **generated, gitignored** — real passwords |
| `k8s/11-configmap-schema.yaml` | generated from `schema.sql` |
| `k8s/20-mysql-statefulset.yaml` | MySQL workload + volumeClaimTemplate |
| `k8s/21-mysql-service.yaml` | headless Service for stable pod DNS |
| `k8s/30-app-deployment.yaml` | app workload, probes, limits |
| `k8s/31-app-service.yaml` | ClusterIP in front of the app pods |
| `k8s/40-ingress.yaml` | host rule `crud.k8s.local` → `crud-app:3000` |
| `k8s/README.md` | runbook: apply, rebuild, teardown, gotchas |
| `server.js` | **modified** — add `/livez` |
| `.gitignore` | **modified** — add `k8s/secret.yaml` |
| `.dockerignore` | **modified** — add `k8s/` and `docs/` |

The numeric prefixes make `kubectl apply -f k8s/` apply in dependency
order: namespace first, then Secret and ConfigMap, then the workloads
that mount them.

**Why the template is `secret.yaml.example`, not `10-secret.example.yaml`.**
`kubectl apply -f k8s/` applies *every* `.yaml` in the directory. The
template declares the same object name as the real Secret
(`crud-db-secret`), so as a `.yaml` it would overwrite the generated
passwords with `REPLACE_ME_ROOT_PASSWORD` — breaking MySQL on the next
apply, and doing it silently. The `.example` suffix puts it outside
kubectl's extension filter (`.yaml`/`.yml`/`.json` only, non-recursive),
and matches the existing `.env.example` / `terraform.tfvars.example`
convention in this repo.

---

### Task 1: Add the `/livez` liveness endpoint

The only application code change in this plan. It exists so the liveness
probe never touches MySQL — see spec §4.4.

**Files:**
- Modify: `server.js` (insert before the 404 handler, currently line 153)

**Interfaces:**
- Consumes: nothing.
- Produces: `GET /livez` → `200 {"ok":true}`, unconditional, no DB
  access. Task 4's `livenessProbe` targets this path.

- [ ] **Step 1: Confirm the insertion point**

`[LAPTOP]`
```bash
cd /var/www/your_domain/crud
grep -n "app.get('/health'" -A 6 server.js
```

Expected: the `/health` handler around line 146, then
`app.use((req, res) => res.status(404).render('404'));` around line 153.
`/livez` goes between them — **after** `/health`, **before** the 404
catch-all. Registered after the catch-all it would never match.

- [ ] **Step 2: Write the failing test — start the app with no database**

`[LAPTOP]`
```bash
cd /var/www/your_domain/crud
DB_HOST=127.0.0.1 DB_PORT=9999 DB_USER=nobody DB_PASSWORD=nothing \
  DB_NAME=crud_db PORT=3999 HOST=127.0.0.1 node server.js &
echo $! > /tmp/livez-test.pid
sleep 2
```

Port 9999 has no MySQL on purpose. `mysql2` pools connect lazily, so the
process starts anyway — which is exactly the condition the two probes
must tell apart.

- [ ] **Step 3: Run the test to verify it fails**

`[LAPTOP]`
```bash
echo -n "/livez  -> "; curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:3999/livez
echo -n "/health -> "; curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:3999/health
```

Expected **now**: `/livez -> 404` (route doesn't exist yet),
`/health -> 500` (database unreachable).

- [ ] **Step 4: Write the implementation**

Insert into `server.js` immediately after the `/health` handler's
closing `}));` and before `app.use((req, res) => res.status(404)...`:

```js
// Liveness, not health. Answers only "is this process still serving?"
// and deliberately does NOT touch the database.
//
// /health runs SELECT 1 and is the right READINESS probe: when MySQL is
// unreachable the pod should stop receiving traffic. It is the wrong
// LIVENESS probe, because a MySQL blip would then make Kubernetes kill
// every app pod, repeatedly, in a restart loop that cannot fix a
// database problem and removes the application on top of it.
app.get('/livez', (req, res) => res.json({ ok: true }));
```

- [ ] **Step 5: Restart the app and verify the test passes**

`[LAPTOP]`
```bash
cd /var/www/your_domain/crud
kill "$(cat /tmp/livez-test.pid)" 2>/dev/null
DB_HOST=127.0.0.1 DB_PORT=9999 DB_USER=nobody DB_PASSWORD=nothing \
  DB_NAME=crud_db PORT=3999 HOST=127.0.0.1 node server.js &
echo $! > /tmp/livez-test.pid
sleep 2
echo -n "/livez  -> "; curl -s -w ' %{http_code}\n' http://127.0.0.1:3999/livez
echo -n "/health -> "; curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:3999/health
```

Expected: `/livez -> {"ok":true} 200` and `/health -> 500`.

**This divergence is the whole point of the task.** The same process,
with the database down, is *live* but not *ready*. If both return the
same code, the probes cannot distinguish the two states and Task 4's
configuration is pointless.

- [ ] **Step 6: Stop the test server and lint**

`[LAPTOP]`
```bash
kill "$(cat /tmp/livez-test.pid)" 2>/dev/null; rm -f /tmp/livez-test.pid
cd /var/www/your_domain/crud && npm run lint
```

Expected: no errors.

- [ ] **Step 7: Commit**

`[LAPTOP]`
```bash
cd /var/www/your_domain/crud
git add server.js
git commit -m "Add /livez shallow liveness endpoint

Kubernetes liveness probes must not run a database query: a MySQL blip
would otherwise restart every app pod in a loop that cannot fix it.
/health keeps SELECT 1 and becomes the readiness probe instead.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: Namespace, Secret and schema ConfigMap

The foundation objects. Nothing can mount what does not exist, so these
land before any workload.

**Files:**
- Create: `k8s/00-namespace.yaml`
- Create: `k8s/secret.yaml.example`
- Create: `k8s/11-configmap-schema.yaml` (generated)
- Modify: `.gitignore`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - Namespace `crud`
  - Secret `crud-db-secret` with keys `MYSQL_ROOT_PASSWORD`,
    `MYSQL_PASSWORD` — consumed by Tasks 3 and 4
  - ConfigMap `crud-db-schema` with key `schema.sql` — mounted by Task 3

- [ ] **Step 1: Gitignore the generated Secret — before it exists**

Append to `.gitignore`:

```gitignore
# Generated Kubernetes Secret: real passwords, base64-encoded.
# base64 is ENCODING, NOT ENCRYPTION — anyone with this file has the
# password. Regenerate it with the command in k8s/README.md.
# The tracked template is k8s/secret.example.yaml.
k8s/secret.yaml
```

Order matters: this is committed in Step 2, *before* Step 7 generates
the file, so the real Secret is never momentarily trackable.

- [ ] **Step 2: Commit the gitignore entry on its own**

`[LAPTOP]`
```bash
cd /var/www/your_domain/crud
git add .gitignore
git commit -m "Gitignore the generated Kubernetes Secret before creating it"
```

- [ ] **Step 3: Create the namespace manifest**

Create `k8s/00-namespace.yaml`:

```yaml
# Everything this project puts in the cluster lives here, so the whole
# stack can be removed with a single `kubectl delete namespace crud`.
apiVersion: v1
kind: Namespace
metadata:
  name: crud
```

- [ ] **Step 4: Create the tracked Secret template**

Create `k8s/secret.yaml.example`:

```yaml
# TEMPLATE ONLY — placeholders. Safe to commit. Do not apply this.
#
# The `.example` suffix is load-bearing: `kubectl apply -f k8s/` applies
# every .yaml in the directory, and this file declares the SAME object
# name as the real Secret. As a .yaml it would silently overwrite the
# generated passwords with the placeholders below and break MySQL.
#
# A Kubernetes Secret is base64, which is ENCODING, NOT ENCRYPTION.
# Anyone who can read the YAML can read the password. The real Secret is
# generated (never hand-edited) and k8s/secret.yaml is gitignored:
#
#   kubectl create secret generic crud-db-secret -n crud \
#     --from-literal=MYSQL_ROOT_PASSWORD="$(openssl rand -base64 24 | tr -d '/+=' | cut -c1-24)" \
#     --from-literal=MYSQL_PASSWORD="$(openssl rand -base64 24 | tr -d '/+=' | cut -c1-24)" \
#     --dry-run=client -o yaml > k8s/secret.yaml
#
# Both workloads read this one Secret, so each password exists in
# exactly one place. The app receives MYSQL_PASSWORD under the name
# DB_PASSWORD via secretKeyRef — same value, different env var name.
apiVersion: v1
kind: Secret
metadata:
  name: crud-db-secret
  namespace: crud
type: Opaque
stringData:
  MYSQL_ROOT_PASSWORD: REPLACE_ME_ROOT_PASSWORD
  MYSQL_PASSWORD: REPLACE_ME_APP_PASSWORD
```

- [ ] **Step 5: Apply the namespace**

`[LAPTOP]`
```bash
cd /var/www/your_domain/crud
kubectl apply -f k8s/00-namespace.yaml
kubectl get namespace crud
```

Expected: `namespace/crud created`, then status `Active`.

- [ ] **Step 6: Generate the schema ConfigMap from `schema.sql`**

`[LAPTOP]`
```bash
cd /var/www/your_domain/crud
kubectl create configmap crud-db-schema \
  --from-file=schema.sql \
  -n crud --dry-run=client -o yaml > k8s/11-configmap-schema.yaml
head -5 k8s/11-configmap-schema.yaml
grep -c "CREATE TABLE IF NOT EXISTS users" k8s/11-configmap-schema.yaml
```

Expected: a ConfigMap manifest; the grep prints `1`.

Generated, never transcribed — so it cannot drift from `schema.sql`.
Regeneration is the same command, recorded in `k8s/README.md`.

`schema.sql` is 1 176 bytes, far inside the 1 MiB ConfigMap limit.

- [ ] **Step 7: Generate the real Secret**

`[LAPTOP]`
```bash
cd /var/www/your_domain/crud
kubectl create secret generic crud-db-secret -n crud \
  --from-literal=MYSQL_ROOT_PASSWORD="$(openssl rand -base64 24 | tr -d '/+=' | cut -c1-24)" \
  --from-literal=MYSQL_PASSWORD="$(openssl rand -base64 24 | tr -d '/+=' | cut -c1-24)" \
  --dry-run=client -o yaml > k8s/secret.yaml
git check-ignore -v k8s/secret.yaml
```

Expected: `git check-ignore` echoes the `.gitignore` rule that matches.
**If it prints nothing, stop** — the file is trackable and must not be
committed. Fix `.gitignore` before continuing.

- [ ] **Step 8: Apply the Secret and ConfigMap**

`[LAPTOP]`
```bash
cd /var/www/your_domain/crud
kubectl apply -f k8s/secret.yaml -f k8s/11-configmap-schema.yaml
kubectl get secret,configmap -n crud
```

Expected: `crud-db-secret` with `DATA  2`, and `crud-db-schema` with
`DATA  1`. (A `kube-root-ca.crt` ConfigMap is also present; Kubernetes
creates that in every namespace.)

- [ ] **Step 9: Test the Review-Focus failure mode — a mis-keyed Secret**

Proves what a *missing* key looks like, so it is recognisable later.

`[LAPTOP]`
```bash
cd /var/www/your_domain/crud
kubectl run secret-probe -n crud --image=busybox:1.36 --restart=Never \
  --overrides='{"spec":{"containers":[{"name":"secret-probe","image":"busybox:1.36","command":["sh","-c","echo ok"],"env":[{"name":"X","valueFrom":{"secretKeyRef":{"name":"crud-db-secret","key":"NO_SUCH_KEY"}}}]}]}}'
sleep 5
kubectl get pod secret-probe -n crud
kubectl delete pod secret-probe -n crud --force --grace-period=0 2>/dev/null
```

Expected: the pod sits in **`CreateContainerConfigError`**, not
`CrashLoopBackOff`. That distinction matters — a config error means the
container never started, so `kubectl logs` is empty and only
`kubectl describe pod` explains why.

- [ ] **Step 10: Verify the real keys resolve**

`[LAPTOP]`
```bash
kubectl get secret crud-db-secret -n crud -o jsonpath='{.data.MYSQL_ROOT_PASSWORD}' | base64 -d | wc -c
kubectl get secret crud-db-secret -n crud -o jsonpath='{.data.MYSQL_PASSWORD}' | base64 -d | wc -c
```

Expected: `24` from each. (That `base64 -d` round-trip is itself the
demonstration that a Secret is not encrypted.)

- [ ] **Step 11: Commit**

`[LAPTOP]`
```bash
cd /var/www/your_domain/crud
git add k8s/00-namespace.yaml k8s/secret.yaml.example k8s/11-configmap-schema.yaml
git status --short
git commit -m "Add k8s namespace, Secret template and schema ConfigMap

The ConfigMap is generated from schema.sql rather than transcribed, so
the two cannot drift. The real Secret is generated separately and is
gitignored; only the placeholder template is tracked.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

`git status --short` must **not** list `k8s/secret.yaml`.

---

### Task 3: MySQL StatefulSet, headless Service and PVC

**Files:**
- Create: `k8s/20-mysql-statefulset.yaml`
- Create: `k8s/21-mysql-service.yaml`

**Interfaces:**
- Consumes: namespace `crud`, Secret `crud-db-secret`
  (`MYSQL_ROOT_PASSWORD`, `MYSQL_PASSWORD`), ConfigMap `crud-db-schema`
  (key `schema.sql`) — all from Task 2.
- Produces: MySQL reachable at **`crud-db-0.crud-db:3306`**, database
  `crud_db`, user `crud_user`. Task 4's `DB_HOST` is exactly that
  hostname.

- [ ] **Step 1: Create the headless Service**

Create `k8s/21-mysql-service.yaml`:

```yaml
# Headless: clusterIP None means no virtual IP and no load balancing.
# Instead, DNS returns the pod's own address, which is what gives the
# StatefulSet member its stable name:
#
#   crud-db-0.crud-db.crud.svc.cluster.local
#
# Inside this namespace, `crud-db-0.crud-db` is enough. A database is a
# thing you address directly, not something to round-robin across.
apiVersion: v1
kind: Service
metadata:
  name: crud-db
  namespace: crud
  labels:
    app: crud-db
spec:
  clusterIP: None
  selector:
    app: crud-db
  ports:
    - name: mysql
      port: 3306
      targetPort: mysql
```

- [ ] **Step 2: Create the StatefulSet**

Create `k8s/20-mysql-statefulset.yaml`:

```yaml
# StatefulSet rather than Deployment, for two reasons:
#
#  1. A Deployment with a ReadWriteOnce PVC DEADLOCKS on rolling update:
#     the new pod cannot mount the volume while the old pod still holds
#     it, and the old pod is not removed until the new one is Ready.
#     A StatefulSet terminates before it creates, so it cannot deadlock.
#  2. Stable identity: this pod is always `crud-db-0`, so the app has a
#     fixed hostname to point at.
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: crud-db
  namespace: crud
spec:
  serviceName: crud-db        # MUST match the headless Service's name
  replicas: 1
  selector:
    matchLabels:
      app: crud-db
  template:
    metadata:
      labels:
        app: crud-db
    spec:
      containers:
        - name: mysql
          # Stock image. The Compose stack builds a custom one only to
          # work around Docker Desktop refusing to bind-mount /var/www;
          # a ConfigMap has no such problem, so no custom image here.
          image: mysql:8.4
          ports:
            - name: mysql
              containerPort: 3306
          env:
            # The entrypoint processes these BEFORE running the files in
            # /docker-entrypoint-initdb.d, so the database and the
            # crud_user@'%' account already exist when schema.sql runs.
            - name: MYSQL_DATABASE
              value: crud_db
            - name: MYSQL_USER
              value: crud_user
            - name: MYSQL_ROOT_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: crud-db-secret
                  key: MYSQL_ROOT_PASSWORD
            - name: MYSQL_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: crud-db-secret
                  key: MYSQL_PASSWORD
          volumeMounts:
            - name: data
              mountPath: /var/lib/mysql
            - name: schema
              mountPath: /docker-entrypoint-initdb.d
          resources:
            requests:
              memory: 512Mi
              cpu: 250m
            limits:
              memory: 1Gi
              cpu: 1000m
          # failureThreshold 30 x periodSeconds 5 = 150s of grace.
          # First-boot initialisation takes 60-90s on this hardware;
          # a tighter budget restarts MySQL in the middle of it, forever.
          readinessProbe:
            exec:
              command:
                - sh
                - -c
                - mysqladmin ping -h 127.0.0.1 -uroot -p"$MYSQL_ROOT_PASSWORD" --silent
            initialDelaySeconds: 15
            periodSeconds: 5
            timeoutSeconds: 5
            failureThreshold: 30
          # Deliberately shallow, and deliberately generous. A liveness
          # probe that runs a query would kill MySQL during a long crash
          # recovery — exactly when killing it is worst.
          livenessProbe:
            tcpSocket:
              port: mysql
            initialDelaySeconds: 90
            periodSeconds: 20
            failureThreshold: 3
      volumes:
        - name: schema
          configMap:
            name: crud-db-schema
  # Not a plain PVC: volumeClaimTemplates gives each replica its own
  # volume, and the volume SURVIVES the pod. storageClassName is omitted
  # so the cluster default (hostpath) is used.
  #
  # WARNING: that StorageClass has reclaimPolicy Delete. Deleting this
  # PVC destroys the data permanently. Deleting the POD does not.
  volumeClaimTemplates:
    - metadata:
        name: data
      spec:
        accessModes: ["ReadWriteOnce"]
        resources:
          requests:
            storage: 2Gi
```

- [ ] **Step 3: Apply both**

`[LAPTOP]`
```bash
cd /var/www/your_domain/crud
kubectl apply -f k8s/21-mysql-service.yaml -f k8s/20-mysql-statefulset.yaml
```

- [ ] **Step 4: Watch it come up**

`[LAPTOP]`
```bash
kubectl get pods -n crud -w
```

Expected progression: `Pending` → `ContainerCreating` → `Running 0/1`
→ (60-90 s later) `Running 1/1`. Press Ctrl+C once it reads `1/1`.

`0/1` while `Running` is the readiness probe correctly reporting that
MySQL has not finished initialising. It is not an error.

- [ ] **Step 5: Verify the PVC bound**

`[LAPTOP]`
```bash
kubectl get pvc -n crud
```

Expected: `data-crud-db-0`, status **`Bound`**, capacity `2Gi`,
storageclass `hostpath`. `Pending` here means no default StorageClass
and nothing below will work.

- [ ] **Step 6: Verify the ConfigMap actually seeded the schema**

`[LAPTOP]`
```bash
kubectl exec -n crud crud-db-0 -- sh -c \
  'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -D crud_db -e "SELECT id,name,status FROM users;"'
```

Expected: the three seed rows — Ada Lovelace, Alan Turing, Grace Hopper.

This is the test that the ConfigMap mount worked. An empty table, or
`ERROR 1146 Table 'crud_db.users' doesn't exist`, means the ConfigMap
did not reach `/docker-entrypoint-initdb.d`.

- [ ] **Step 7: Test the Review-Focus failure mode — init-time patience**

Confirms the readiness budget is genuinely larger than init time.

`[LAPTOP]`
```bash
kubectl get events -n crud --field-selector involvedObject.name=crud-db-0 \
  --sort-by=.lastTimestamp -o custom-columns=TIME:.lastTimestamp,REASON:.reason,MSG:.message
kubectl get pod crud-db-0 -n crud -o jsonpath='{.status.containerStatuses[0].restartCount}{"\n"}'
```

Expected: restart count **`0`**, and no `Killing` / `Unhealthy` events
for the liveness probe. Any restart during first boot means the probe
budget is too tight and MySQL is being killed mid-initialisation.

- [ ] **Step 8: Verify the app's future DB hostname resolves**

`[LAPTOP]`
```bash
kubectl run dns-probe -n crud --image=busybox:1.36 --restart=Never --rm -it -- \
  nslookup crud-db-0.crud-db
```

Expected: an answer resolving `crud-db-0.crud-db.crud.svc.cluster.local`
to the pod IP. This is the exact string Task 4 sets as `DB_HOST`; if it
does not resolve here, the app will not connect.

- [ ] **Step 9: Commit**

`[LAPTOP]`
```bash
cd /var/www/your_domain/crud
git add k8s/20-mysql-statefulset.yaml k8s/21-mysql-service.yaml
git commit -m "Add MySQL StatefulSet, headless Service and 2Gi PVC

StatefulSet rather than Deployment: a Deployment with a ReadWriteOnce
PVC deadlocks on rolling update, and the app needs a stable hostname.
Readiness allows 150s because first-boot init takes 60-90s; liveness is
a TCP check so a long crash recovery is never interrupted.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: App image, Deployment and Service

**Files:**
- Create: `k8s/30-app-deployment.yaml`
- Create: `k8s/31-app-service.yaml`

**Interfaces:**
- Consumes: Secret `crud-db-secret` key `MYSQL_PASSWORD` (Task 2);
  MySQL at `crud-db-0.crud-db:3306` (Task 3); `GET /livez` (Task 1).
- Produces: Service `crud-app` on port **3000** in namespace `crud`,
  selecting `app: crud-app`. Task 5's Ingress backend is exactly that
  name and port.

- [ ] **Step 1: Build the image into the shared Docker store**

`[LAPTOP]`
```bash
cd /var/www/your_domain/crud
docker build -t crud-app:k8s .
docker image ls crud-app
```

Expected: a `crud-app` repository with tag `k8s`.

Docker Desktop's Kubernetes shares this image store, so no registry,
no push. The tag must be explicit: `imagePullPolicy: Never` combined
with `:latest` silently keeps running a stale image.

- [ ] **Step 2: Create the Deployment**

Create `k8s/30-app-deployment.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: crud-app
  namespace: crud
spec:
  # Two, not one. A Service load-balancing to a single pod demonstrates
  # nothing, and a rolling update with one replica leaves no pod serving.
  replicas: 2
  selector:
    matchLabels:
      app: crud-app
  template:
    metadata:
      labels:
        app: crud-app
    spec:
      containers:
        - name: app
          image: crud-app:k8s
          # Never: the image is already in the local Docker store, and
          # the default would try to pull it from Docker Hub and fail
          # with ErrImagePull.
          #
          # CONSEQUENCE: after any `docker build`, these pods keep
          # running the OLD image until you run
          #   kubectl rollout restart deployment/crud-app -n crud
          imagePullPolicy: Never
          ports:
            - name: http
              containerPort: 3000
          env:
            # The image already sets these, but stating them here makes
            # the pod spec self-describing.
            - name: HOST
              value: "0.0.0.0"       # loopback would be unreachable
            - name: PORT
              value: "3000"
            - name: DB_HOST
              value: crud-db-0.crud-db
            - name: DB_PORT
              value: "3306"
            - name: DB_NAME
              value: crud_db
            - name: DB_USER
              value: crud_user
            # Same Secret key as MySQL's own MYSQL_PASSWORD, surfaced
            # under the name this app expects. One value, one place.
            - name: DB_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: crud-db-secret
                  key: MYSQL_PASSWORD
          # Deep: runs SELECT 1. Correct here — while MySQL is
          # unreachable this pod should receive no traffic.
          readinessProbe:
            httpGet:
              path: /health
              port: http
            initialDelaySeconds: 5
            periodSeconds: 5
            timeoutSeconds: 3
            failureThreshold: 6
          # Shallow: never touches the database. See spec section 4.4 —
          # a deep liveness probe turns a MySQL blip into an endless
          # app-pod restart loop that cannot fix anything.
          livenessProbe:
            httpGet:
              path: /livez
              port: http
            initialDelaySeconds: 15
            periodSeconds: 20
            failureThreshold: 3
          resources:
            requests:
              memory: 128Mi
              cpu: 100m
            limits:
              memory: 256Mi
              cpu: 500m
```

- [ ] **Step 3: Create the Service**

Create `k8s/31-app-service.yaml`:

```yaml
# ClusterIP: reachable inside the cluster only. Traefik is the single
# public entry point, exactly as nginx is on the EC2 box.
apiVersion: v1
kind: Service
metadata:
  name: crud-app
  namespace: crud
  labels:
    app: crud-app
spec:
  type: ClusterIP
  selector:
    app: crud-app       # matches the Deployment's pod labels
  ports:
    - name: http
      port: 3000        # the port the Ingress targets
      targetPort: http  # the container's named port
```

- [ ] **Step 4: Apply both**

`[LAPTOP]`
```bash
cd /var/www/your_domain/crud
kubectl apply -f k8s/30-app-deployment.yaml -f k8s/31-app-service.yaml
kubectl rollout status deployment/crud-app -n crud --timeout=120s
```

Expected: `deployment "crud-app" successfully rolled out`.

- [ ] **Step 5: Verify both replicas are Ready**

`[LAPTOP]`
```bash
kubectl get pods -n crud -l app=crud-app -o wide
```

Expected: two pods, each `1/1 Running`, restart count `0`.

- [ ] **Step 6: Verify the Service found both pods**

`[LAPTOP]`
```bash
kubectl get endpointslice -n crud -l kubernetes.io/service-name=crud-app \
  -o jsonpath='{range .items[*].endpoints[*]}{.addresses[0]}{"\n"}{end}'
```

Expected: **two** IP addresses. One means a pod is not Ready; none means
the Service selector does not match the pod labels.

- [ ] **Step 7: Verify the app actually serves, bypassing the ingress**

`[LAPTOP]`
```bash
kubectl port-forward -n crud svc/crud-app 3999:3000 >/dev/null 2>&1 &
echo $! > /tmp/pf.pid
sleep 3
curl -s http://127.0.0.1:3999/health; echo
curl -s http://127.0.0.1:3999/ | grep -c "Ada Lovelace"
kill "$(cat /tmp/pf.pid)"; rm -f /tmp/pf.pid
```

Expected: `{"ok":true,"db":"up"}` and `1`.

Testing through `port-forward` first isolates the app from the ingress.
If this works and Task 5 does not, the fault is in the ingress — not here.

- [ ] **Step 8: Test the Review-Focus failure mode — app starts before MySQL**

Proves readiness holds traffic back rather than the pod crash-looping.

`[LAPTOP]`
```bash
kubectl scale statefulset/crud-db -n crud --replicas=0
kubectl wait --for=delete pod/crud-db-0 -n crud --timeout=90s
kubectl rollout restart deployment/crud-app -n crud
sleep 30
kubectl get pods -n crud -l app=crud-app
kubectl get endpointslice -n crud -l kubernetes.io/service-name=crud-app \
  -o jsonpath='{range .items[*].endpoints[*]}{.addresses[0]}{"\n"}{end}'
```

Expected: pods `Running` but **`0/1`**, and **no** endpoint addresses —
readiness is correctly withholding traffic. Restart count must stay low:
the pods must not be in `CrashLoopBackOff`, because the liveness probe
does not touch the database.

Now restore:

`[LAPTOP]`
```bash
kubectl scale statefulset/crud-db -n crud --replicas=1
kubectl wait --for=condition=ready pod/crud-db-0 -n crud --timeout=180s
kubectl wait --for=condition=available deployment/crud-app -n crud --timeout=120s
kubectl get pods -n crud
```

Expected: everything back to `1/1`. **The app pods recovered on their
own** — no restart needed, because they were never killed. That is the
payoff for splitting `/livez` from `/health`.

- [ ] **Step 9: Commit**

`[LAPTOP]`
```bash
cd /var/www/your_domain/crud
git add k8s/30-app-deployment.yaml k8s/31-app-service.yaml
git commit -m "Add app Deployment and ClusterIP Service

Two replicas so the Service has something to balance and a rolling
update has a surviving pod. Readiness uses /health (deep), liveness uses
/livez (shallow), so a database outage withholds traffic instead of
restarting the application.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: Traefik ingress controller and the Ingress

**Files:**
- Create: `k8s/40-ingress.yaml`
- Modify: `/etc/hosts` (outside the repo, needs `sudo`)

**Interfaces:**
- Consumes: Service `crud-app:3000` (Task 4).
- Produces: `http://crud.k8s.local:8080` serving the app.

- [ ] **Step 1: Confirm the port conflict is real before working around it**

`[LAPTOP]`
```bash
ss -ltn | grep -E ':(80|443|8080)\s' || echo "(80/443/8080 all free)"
systemctl is-active apache2
```

Expected: `*:80` listening, apache2 `active`. That is why the cluster
uses 8080 — stopping Apache would break the existing `crud.local` vhost.

If 8080 is *also* listed, stop and use the NodePort contingency in
spec §4.5 instead.

- [ ] **Step 2: Install Helm, verifying the download**

`[LAPTOP]`
```bash
cd /tmp
HELM_VER=$(curl -fsSL https://api.github.com/repos/helm/helm/releases/latest \
  | grep -oP '"tag_name":\s*"\K[^"]+')
echo "Installing Helm $HELM_VER"
curl -fsSLO "https://get.helm.sh/helm-${HELM_VER}-linux-amd64.tar.gz"
curl -fsSLO "https://get.helm.sh/helm-${HELM_VER}-linux-amd64.tar.gz.sha256sum"
sha256sum -c "helm-${HELM_VER}-linux-amd64.tar.gz.sha256sum"
```

Expected: `helm-<version>-linux-amd64.tar.gz: OK`.

**If the checksum does not say OK, stop.** Same discipline as the
Terraform binary install — verify before executing.

- [ ] **Step 3: Put Helm on the PATH** — needs `sudo`

`[LAPTOP]`
```bash
cd /tmp
tar -xzf "helm-${HELM_VER}-linux-amd64.tar.gz"
sudo install -m 0755 linux-amd64/helm /usr/local/bin/helm
rm -rf linux-amd64 helm-*.tar.gz*
helm version
```

Expected: a version line matching `$HELM_VER`.

- [ ] **Step 4: Install Traefik**

`[LAPTOP]`
```bash
helm repo add traefik https://traefik.github.io/charts
helm repo update
helm install traefik traefik/traefik \
  --namespace traefik --create-namespace \
  --set ports.web.exposedPort=8080 \
  --set ports.websecure.expose.default=false
```

- `ports.web.exposedPort=8080` sets the **Service** port. Docker Desktop
  fulfils `LoadBalancer` services by binding the service port on
  localhost. (`ports.web.port` is the *container* port — leave it.)
- `ports.websecure.expose.default=false` drops the unused 443 listener.
  TLS is out of scope locally, and an unused bound port is one more
  thing to collide with.

Traefik rather than ingress-nginx because ingress-nginx was retired on
2026-03-24 — no releases, no bug fixes, no security patches. The
`Ingress` resource below is unchanged by that swap.

- [ ] **Step 5: Verify the controller bound port 8080**

`[LAPTOP]`
```bash
kubectl rollout status deployment/traefik -n traefik --timeout=120s
kubectl get svc -n traefik traefik
ss -ltn | grep ':8080' || echo "8080 NOT BOUND"
```

Expected: `EXTERNAL-IP` showing `localhost`, port mapping including
`8080`, and `ss` showing 8080 listening.

**If `EXTERNAL-IP` is `<pending>` or 8080 is not bound**, apply the
contingency from spec §4.5:

```bash
helm upgrade traefik traefik/traefik --namespace traefik \
  --set service.type=NodePort \
  --set ports.web.nodePort=30080 \
  --set ports.websecure.expose.default=false
```

…and substitute `30080` for `8080` everywhere below.

- [ ] **Step 6: Confirm the IngressClass name**

`[LAPTOP]`
```bash
kubectl get ingressclass
```

Expected: an entry named **`traefik`**. If the chart named it something
else, use that exact name in Step 7 instead.

- [ ] **Step 7: Create the Ingress**

Create `k8s/40-ingress.yaml`:

```yaml
# The public entry point, and the Kubernetes equivalent of the nginx
# server block on the EC2 box.
#
# Host is crud.k8s.local, NOT crud.local: Apache already owns port 80
# and /etc/hosts already points crud.local at it. Separate hostname and
# separate port means both deployments run side by side.
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: crud
  namespace: crud
spec:
  ingressClassName: traefik
  rules:
    - host: crud.k8s.local
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: crud-app
                port:
                  number: 3000
```

- [ ] **Step 8: Add the hosts entry** — needs `sudo`

`[LAPTOP]`
```bash
grep -q "crud.k8s.local" /etc/hosts \
  || echo "127.0.0.1 crud.k8s.local" | sudo tee -a /etc/hosts
grep -n "crud" /etc/hosts
```

Expected: both `crud.local` (Apache, untouched) and `crud.k8s.local`.

- [ ] **Step 9: Apply and test — including the Host-header failure mode**

`[LAPTOP]`
```bash
cd /var/www/your_domain/crud
kubectl apply -f k8s/40-ingress.yaml
sleep 5
echo -n "correct host   -> "; curl -s -o /dev/null -w '%{http_code}\n' http://crud.k8s.local:8080/health
echo -n "wrong host     -> "; curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8080/health
echo -n "payload        -> "; curl -s http://crud.k8s.local:8080/health
```

Expected: correct host `200`, **wrong host `404`**, payload
`{"ok":true,"db":"up"}`.

That 404 is the Review-Focus failure mode and it is *correct behaviour*,
not a fault. Traefik routes on the `Host` header, so the right app on
the right port still 404s under the wrong name — the same class of
confusion as the certbot `server_name` 404 on the EC2 box.

- [ ] **Step 10: Commit**

`[LAPTOP]`
```bash
cd /var/www/your_domain/crud
git add k8s/40-ingress.yaml
git commit -m "Add Ingress on crud.k8s.local:8080 via Traefik

Separate hostname and port from the Apache vhost on crud.local, so both
deployments of this app run side by side with no disruption. Traefik
rather than ingress-nginx, which was retired on 2026-03-24.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 6: Runbook, dockerignore, and the three acceptance tests

**Files:**
- Create: `k8s/README.md`
- Modify: `.dockerignore`

**Interfaces:**
- Consumes: everything from Tasks 1-5.
- Produces: nothing other tasks depend on. This is the last task.

- [ ] **Step 1: Exclude `k8s/` and `docs/` from the image build context**

Append to `.dockerignore`:

```
# Kubernetes manifests and specs — cluster and repo tooling, not runtime
# files. k8s/secret.yaml in particular must never reach an image.
#
# Note the existing `*.md` rule above does NOT cover docs/: Docker
# patterns do not cross a `/`, so `*.md` matches only top-level files.
k8s/
docs/
```

- [ ] **Step 2: Verify the exclusion actually works**

`[LAPTOP]`
```bash
cd /var/www/your_domain/crud
docker build -t crud-app:k8s . 2>&1 | tail -3
docker run --rm --entrypoint sh crud-app:k8s -c 'ls -a /app | grep -E "^(k8s|docs)$" && echo "LEAK" || echo "clean: no k8s/ or docs/ in image"'
```

Expected: `clean: no k8s/ or docs/ in image`.

- [ ] **Step 3: Write the runbook**

Create `k8s/README.md`:

````markdown
# Running this app on local Kubernetes

Laptop only. This changes nothing about the EC2 production deployment,
which still runs Docker Compose behind nginx.

Design and rationale: [`../docs/superpowers/specs/2026-10-04-kubernetes-local-design.md`](../docs/superpowers/specs/2026-10-04-kubernetes-local-design.md)

## Prerequisites

- Docker Desktop with Kubernetes enabled (`kubectl config use-context docker-desktop`)
- `127.0.0.1 crud.k8s.local` in `/etc/hosts`
- Traefik installed (see "First-time setup")

## Everyday use

```bash
# Build the image and bring the whole stack up
docker build -t crud-app:k8s .
kubectl apply -f k8s/

# Watch it settle
kubectl get pods -n crud -w

# Open it
#   http://crud.k8s.local:8080
```

## After changing application code

`imagePullPolicy: Never` means the pods keep running the **old** image
until they are restarted. Rebuilding alone does nothing:

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

Note this only affects a **fresh** database. The MySQL entrypoint runs
`/docker-entrypoint-initdb.d` only when the data directory is empty, so
an existing PVC ignores the new schema entirely.

## First-time setup

```bash
# 1. Traefik (ingress-nginx was retired 2026-03-24)
helm repo add traefik https://traefik.github.io/charts
helm repo update
helm install traefik traefik/traefik \
  --namespace traefik --create-namespace \
  --set ports.web.exposedPort=8080 \
  --set ports.websecure.expose.default=false

# 2. Generate the Secret (gitignored, never hand-edited)
kubectl apply -f k8s/00-namespace.yaml
kubectl create secret generic crud-db-secret -n crud \
  --from-literal=MYSQL_ROOT_PASSWORD="$(openssl rand -base64 24 | tr -d '/+=' | cut -c1-24)" \
  --from-literal=MYSQL_PASSWORD="$(openssl rand -base64 24 | tr -d '/+=' | cut -c1-24)" \
  --dry-run=client -o yaml > k8s/secret.yaml

# 3. Everything else
docker build -t crud-app:k8s .
kubectl apply -f k8s/
```

Port 8080, not 80, because Apache holds 80 on this laptop and already
serves the Compose version of this app at `crud.local`. The two run
side by side.

## Teardown

```bash
# Stop the workloads, KEEP the database
kubectl delete -f k8s/30-app-deployment.yaml -f k8s/20-mysql-statefulset.yaml

# Remove everything INCLUDING the database, permanently
kubectl delete namespace crud
```

> **The PVC is where your data lives.** The `hostpath` StorageClass has
> reclaim policy `Delete`, so deleting the PVC — or the namespace that
> contains it — destroys the rows with no recovery. Deleting the *pod*
> is safe: that is what verification test 2 proves.

## Troubleshooting

| Symptom | Cause |
|---|---|
| `ErrImagePull` on `crud-app:k8s` | Image not built locally, or `imagePullPolicy` is not `Never` |
| Code change has no effect | Pods still running the old image — `kubectl rollout restart` |
| `CreateContainerConfigError` | Secret missing or a key is misspelled. `kubectl logs` is empty; use `kubectl describe pod` |
| App pods `Running 0/1`, no endpoints | Readiness failing — MySQL is down. Working as designed |
| 404 from `localhost:8080` | Traefik routes on the `Host` header. Use `crud.k8s.local:8080` |
| `crud-db-0` PVC `Pending` | No default StorageClass |
| Traefik `EXTERNAL-IP <pending>` | Port 8080 already taken; see spec §4.5 NodePort contingency |

## What this does NOT cover

metrics-server (`kubectl top`), HorizontalPodAutoscaler, NetworkPolicy,
TLS, Helm packaging of this app, and CI. See spec §10.
````

- [ ] **Step 4: Acceptance test 1 — it serves, and re-applying is safe**

First prove the runbook's everyday command does not destroy the Secret.
`kubectl apply -f k8s/` applies every `.yaml` in the directory, and the
template declares the same object name — this confirms the `.example`
suffix keeps it out of the way.

`[LAPTOP]`
```bash
cd /var/www/your_domain/crud
BEFORE=$(kubectl get secret crud-db-secret -n crud -o jsonpath='{.data.MYSQL_PASSWORD}')
kubectl apply -f k8s/
AFTER=$(kubectl get secret crud-db-secret -n crud -o jsonpath='{.data.MYSQL_PASSWORD}')
[ "$BEFORE" = "$AFTER" ] && echo "SECRET INTACT" || echo "SECRET CLOBBERED — the template was applied"
kubectl get secret crud-db-secret -n crud -o jsonpath='{.data.MYSQL_PASSWORD}' \
  | base64 -d | grep -q "REPLACE_ME" && echo "PLACEHOLDER LEAKED IN" || echo "real password still in place"
```

Expected: `SECRET INTACT` and `real password still in place`.

Then the service test:

`[LAPTOP]`
```bash
echo -n "health    -> "; curl -s http://crud.k8s.local:8080/health; echo
echo -n "seed rows -> "; curl -s http://crud.k8s.local:8080/api/users | grep -o '"name"' | wc -l
echo -n "html      -> "; curl -s -o /dev/null -w '%{http_code}\n' http://crud.k8s.local:8080/
```

Expected: `{"ok":true,"db":"up"}`, `3`, `200`.

`/api/users` returns JSON, so the row count is unambiguous — grepping
rendered HTML would also match a name appearing in markup or a form.

- [ ] **Step 5: Acceptance test 2 — storage survives pod destruction**

The only test that justifies the StatefulSet and the PVC.

`[LAPTOP]`
```bash
# Add a distinctive row through the running app.
# POST /users is the form handler at server.js:63.
curl -s -X POST http://crud.k8s.local:8080/users \
  --data-urlencode "name=Persistence Probe" \
  --data-urlencode "email=probe@example.com" \
  --data-urlencode "phone=+1-555-0199" \
  --data-urlencode "status=active" -o /dev/null -w 'POST %{http_code}\n'
curl -s http://crud.k8s.local:8080/api/users | grep -c "Persistence Probe"
```

Expected: a `302` (the handler redirects after a successful insert) and
then `1`.

Now destroy the database pod and check the row outlives it:

`[LAPTOP]`
```bash
kubectl delete pod crud-db-0 -n crud
kubectl wait --for=condition=ready pod/crud-db-0 -n crud --timeout=180s
kubectl wait --for=condition=available deployment/crud-app -n crud --timeout=120s
curl -s http://crud.k8s.local:8080/api/users | grep -c "Persistence Probe"
```

Expected: **`1`** — the row survived the pod being destroyed.

`0` means the database came back seed-only: the PVC is not retaining
data, and the StatefulSet is giving nothing a Deployment with
`emptyDir` would not.

- [ ] **Step 6: Acceptance test 3 — replicas keep serving**

`[LAPTOP]`
```bash
kubectl delete pod -n crud -l app=crud-app --wait=false
for i in $(seq 1 20); do
  curl -s -o /dev/null -w '%{http_code} ' --max-time 3 http://crud.k8s.local:8080/health
  sleep 1
done; echo
kubectl get pods -n crud -l app=crud-app
```

Expected: **`200` throughout**, and two pods back to `1/1`.

Kubernetes deletes the two pods one at a time and the Service routes
only to Ready endpoints, so a surviving replica serves every request.
A few `000` or `502` responses mean both pods went down together — the
Service had no Ready endpoint, which is what the second replica exists
to prevent.

- [ ] **Step 7: Confirm production files were not touched**

`[LAPTOP]`
```bash
cd /var/www/your_domain/crud
# 1d20397 is the spec-amendment commit — the last commit before any of
# this plan's work. A fixed ref, not a HEAD~n count that drifts if the
# number of commits changes.
git diff --stat 1d20397 -- infra/ deploy/ .github/ docker-compose.yml Dockerfile docker/ schema.sql
echo "--- (nothing above means production is untouched) ---"
git status --short
git check-ignore -v k8s/secret.yaml
git ls-files k8s/
```

Expected:
- the `git diff --stat` prints **nothing** — any output means this plan
  escaped its scope and the EC2 production stack was modified
- `git status --short` does not list `k8s/secret.yaml`
- `git check-ignore` echoes the matching `.gitignore` rule
- `git ls-files k8s/` lists the eight tracked files and
  **not** `secret.yaml`

- [ ] **Step 8: Commit**

`[LAPTOP]`
```bash
cd /var/www/your_domain/crud
git add k8s/README.md .dockerignore
git status --short
git commit -m "Add k8s runbook and exclude k8s/ and docs/ from the image

The existing *.md dockerignore rule does not cover docs/, because Docker
patterns do not cross a slash.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

## Done when

- [ ] `http://crud.k8s.local:8080` serves the app in a browser
- [ ] `http://crud.local` still serves the Apache/Compose version, unchanged
- [ ] Acceptance tests 1, 2 and 3 all pass
- [ ] `git status` is clean and `k8s/secret.yaml` is untracked
- [ ] `git diff` against `infra/`, `deploy/`, `.github/` is empty
