# Testing & security ladder for the CI/CD pipeline

Companion to [SECURITY-CI.md](SECURITY-CI.md), which covers Strix specifically.
Strix is the **top** of this ladder, not the bottom. This document is the rest
of it, in the order worth doing.

---

## First, three gates that are not the same thing

"Run tests when CI/CD is deployed" collapses three separate jobs. They need
different tools and they fail differently:

| Gate | When | Question it answers | Failure means |
|---|---|---|---|
| **Pre-merge** | PR opened | Is this change safe to accept? | Don't merge |
| **Pre-deploy** | push to `master`, before SSH | Is this build shippable? | Don't deploy |
| **Post-deploy** | after the stack restarts | Did production actually come back up correctly? | Roll back |

Today only the third exists, and it is one line:

```yaml
code=$(curl -sL -o /dev/null -w '%{http_code}' --max-time 15 "http://$HOST/health")
test "$code" = "200"
```

That passes if nginx answers and the container is alive. It would also pass if
every user row had been wiped, if `/api/users` returned a 500, or if the
certificate expired tomorrow.

---

## The ladder

Ordered by **value per unit of effort**, cheapest and most deterministic first.

| # | Tool | Catches | Runtime | Cost | Deterministic |
|---|---|---|---|---|---|
| 1 | **Dependabot** | Dependency CVEs, stale deps | — | free | yes |
| 2 | **gitleaks** | Secrets committed to git history | ~10s | free | yes |
| 3 | **CodeQL** | SQLi, XSS, path traversal in JS | 2–4 min | free (public repo) | yes |
| 4 | **Smoke tests** | Deploy that "succeeded" but broke the app | ~5s | free | yes |
| 5 | **Trivy** | CVEs in the base images you ship | 1–2 min | free | yes |
| 6 | **Hadolint** | Dockerfile anti-patterns | ~5s | free | yes |
| 7 | **ZAP baseline** | Missing headers, cookie flags, live DAST | 3–5 min | free | mostly |
| 8 | **Semgrep** | Express-specific bad patterns | 1–2 min | free (OSS rules) | yes |
| 9 | **Strix** | Exploitable logic flaws, chained attacks, IDOR | 5–40 min | **LLM $** | no |

Rungs 1–6 are free, fast and give the same answer every run. Rung 9 is the
expensive, non-deterministic layer that finds what the others structurally
cannot. Adding 9 before 1–6 means paying an LLM to rediscover things a free
linter would have told you in ten seconds.

---

## Recommended first four

### 1. Dependabot — cheapest thing on the list

`.github/dependabot.yml`:

```yaml
version: 2
updates:
  - package-ecosystem: npm
    directory: "/"
    schedule:
      interval: weekly
  - package-ecosystem: docker
    directory: "/"
    schedule:
      interval: weekly
  - package-ecosystem: github-actions
    directory: "/"
    schedule:
      interval: weekly
```

Not a workflow — a config file. It opens PRs when `express`, `mysql2`,
`node:22-alpine` or a pinned action has a published advisory. The
`github-actions` block matters: pinned action versions rot silently.

### 2. gitleaks — you have a documented reason for this one

You have already leaked a password into this repo once and fixed it with an
amend and a force-push. A force-push does not reliably remove a blob from
GitHub — it can remain reachable. gitleaks scans the **whole history**, not just
the diff.

```yaml
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0          # full history, or it only sees the last commit

      - name: Install gitleaks
        env:
          GITLEAKS_VERSION: 8.30.1
        run: |
          curl -sSL "https://github.com/gitleaks/gitleaks/releases/download/v${GITLEAKS_VERSION}/gitleaks_${GITLEAKS_VERSION}_linux_x64.tar.gz" \
            | sudo tar -xz -C /usr/local/bin gitleaks

      - name: Scan history for secrets
        run: gitleaks git . --redact --verbose
```

Three details that matter:

- **`git`, not `detect`.** The `detect` subcommand was removed in gitleaks
  v8.30. The commands are now `git` (history), `dir` (filesystem) and `stdin`.
- **The binary, not the action or the Docker image.** `gitleaks-action` is free
  for personal accounts but needs a free licence key for organization-owned
  repos; the Docker image trips git's "dubious ownership" check on a mounted
  volume. Installing the release binary sidesteps both.
- **`--redact` is not optional.** This repo is public, so its build logs are
  public. Without it, a scan that *finds* a secret republishes that secret to
  anyone reading the log.

**Also turn on the native feature** — [GITHUB] Settings → Code security →
**Secret scanning** and **Push protection**. Free for public repos and it
rejects the push *before* the secret ever lands, which gitleaks-in-CI cannot do.

### 3. CodeQL — free SAST, near-zero config

`.github/workflows/codeql.yml`:

```yaml
name: CodeQL

on:
  push:
    branches: [master]
  schedule:
    - cron: '0 4 * * 1'

jobs:
  analyze:
    runs-on: ubuntu-latest
    permissions:
      security-events: write
      contents: read

    steps:
      - uses: actions/checkout@v4

      - uses: github/codeql-action/init@v3
        with:
          languages: javascript-typescript
          queries: security-extended

      - uses: github/codeql-action/analyze@v3
```

Results land in the repo's **Security → Code scanning** tab, not just a log.
`security-extended` is worth the extra minute over the default query pack.

This is the rung that overlaps most with what Strix does statically — and it is
free and repeatable. Your `:id` routes and the EJS views are exactly what its
JS query pack is built for.

### 4. Smoke tests — the one you actually asked for

Node 22 ships a test runner, so this needs **no new dependencies**. Works on
the EC2 box (v22), in the container (`node:22-alpine`) and on your laptop
(nvm v20).

`test/smoke.test.js`:

```js
// Smoke tests: run against a deployed URL, not a local import. They prove the
// running stack works end to end — app, nginx, TLS and database together.
// BASE_URL defaults to the local container so it also runs before deploy.
const { test, before } = require('node:test');
const assert = require('node:assert');

const BASE = process.env.BASE_URL || 'http://127.0.0.1:3000';

async function get(path) {
  const res = await fetch(BASE + path, { redirect: 'follow' });
  return { status: res.status, headers: res.headers, body: await res.text() };
}

test('health reports the database is up', async () => {
  const r = await get('/health');
  assert.equal(r.status, 200);
  const body = JSON.parse(r.body);
  assert.equal(body.ok, true);
  assert.equal(body.db, 'up', 'app is running but cannot reach MySQL');
});

test('the user list renders', async () => {
  const r = await get('/');
  assert.equal(r.status, 200);
  assert.match(r.body, /<table/i, 'list page rendered without a table');
});

test('the API returns users as JSON', async () => {
  const r = await get('/api/users');
  assert.equal(r.status, 200);
  const users = JSON.parse(r.body);
  assert.ok(Array.isArray(users), 'expected an array');
  assert.ok(users.length > 0, 'database reachable but returned zero users');
});

test('a missing user is a 404, not a 500', async () => {
  const r = await get('/api/users/999999');
  assert.equal(r.status, 404);
});

test("a non-numeric id does not leak a stack trace", async () => {
  const r = await get('/api/users/abc');
  assert.ok(r.status < 500, `got ${r.status} — unhandled error path`);
  assert.doesNotMatch(r.body, /at .*\(.*:\d+:\d+\)/, 'stack trace in response');
});
```

`package.json`:

```json
  "scripts": {
    "start": "node server.js",
    "dev": "node --watch server.js",
    "test": "node --test test/"
  }
```

Then replace the verify step in `deploy.yml`:

```yaml
      - name: Smoke test the deployed site
        env:
          BASE_URL: https://${{ secrets.EC2_HOST }}
        run: npm test
```

The third test is the important one. `/health` returning `ok` proves the app can
*connect* to MySQL. `/api/users` returning a non-empty array proves the data
actually survived the deploy — which is precisely the failure mode you hit
during the container migration, when the stack came up healthy on seed rows
instead of your real records.

---

## Rungs 5–8

**Trivy — DONE**, as the `images` job in `.github/workflows/security.yml`.
You ship containers, so base-image CVEs are the most likely real finding on
this whole list. Decisions baked into that job:

| Setting | Choice | Why |
|---|---|---|
| Targets | **both** images, built not pulled | The MySQL image is ours too — it has `schema.sql` baked in. Scanning bare `mysql:8.4` would miss our own layer |
| `vuln-type` | `os,library` | One scan covers Alpine OS packages *and* the npm packages inside the image |
| `severity` | `CRITICAL,HIGH` | Medium and below on a base image is mostly unactionable noise |
| `ignore-unfixed` | `true` | CVEs with no released fix are real but have no action beyond "rebuild later". Set `false` to see the full picture |
| `exit-code` | `'0'` | Report-only until the baseline is triaged — same approach as hadolint |

A weekly `schedule:` trigger was added at the same time, and it matters more
for Trivy than for anything else here: a CVE disclosed against `node:22-alpine`
or `mysql:8.4` makes yesterday's build unsafe today, with no commit to trigger
on. Code-triggered runs would never notice.

**What this scan does and does not tell you.** It scans what CI builds *now*.
Because the base tags float, that is not byte-identical to the image currently
running on EC2 — it is the image your **next deploy** would produce. Useful
question, but not the same as "is the running container clean?". For that you
would scan on the server:

```bash
# [SERVER] — scans what is actually running
docker run --rm -v /var/run/docker.sock:/var/run/docker.sock \
  aquasec/trivy:latest image --severity CRITICAL,HIGH crud-app:latest
```

**Hadolint — DONE**, as the `dockerfiles` job. See `.hadolint.yaml` for the one
rule deliberately accepted and the reasoning behind it.

**ZAP baseline** — the free DAST, and the honest alternative to Strix for most
of what Strix would find on an app this size. It needs the same ephemeral target
described in Phase C of [SECURITY-CI.md](SECURITY-CI.md):

```yaml
      - name: Start an ephemeral target
        run: |
          BIND_ADDR=0.0.0.0 docker compose up -d --build
          for i in $(seq 1 30); do curl -sf http://127.0.0.1:3000/health && break; sleep 3; done

      - uses: zaproxy/action-baseline@v0.15.0
        with:
          target: http://127.0.0.1:3000
          cmd_options: '-a'
```

ZAP is passive by default: it crawls and reports missing headers, cookie flags
and obvious injection points without trying to exploit anything. It will flag
the missing `helmet` headers immediately.

**Semgrep** — `semgrep --config=p/javascript --config=p/express` catches
Express-shaped mistakes that CodeQL's general queries miss.

---

## Do this before adding any scanner

Four findings are guaranteed on every rung of the ladder, because I verified
they are real in `server.js` and `package.json`: no auth, no CSRF, no security
headers, no rate limiting.

**`helmet` is a two-line change with the largest signal-to-effort ratio here:**

```bash
npm install helmet
```

```js
const helmet = require('helmet');
app.use(helmet());
```

That alone clears most of what ZAP's baseline scan will report. Fixing it first
means your first scan result is *signal* rather than a wall of known noise.

CSRF, auth and rate limiting are real application work and belong on the
roadmap, not in the pipeline — but decide consciously whether you are fixing or
accepting each one, and write the decision down. A scanner cannot tell the
difference between "unauthenticated by design" and "we forgot".

---

## Suggested order of work

1. `helmet` + Dependabot config — under 15 minutes, clears future noise
2. gitleaks in CI + native push protection toggle — you have history here
3. Smoke tests, wired into `deploy.yml` in place of the bare curl
4. CodeQL — free SAST, results in the Security tab
5. Trivy + Hadolint on the images
6. ZAP baseline against the ephemeral stack — free DAST
7. **Then** Strix (see [SECURITY-CI.md](SECURITY-CI.md)) — the paid, AI layer,
   now aimed at what the free tools structurally cannot find

Steps 1–4 are a single afternoon and cost nothing. That is the answer to "what
first".

---

## Where each one runs

```
PR opened ──────► gitleaks · CodeQL · Semgrep · smoke (local stack) · ZAP
                  └─ fast, free, blocks the merge

push master ────► build image ──► Trivy ──► deploy.yml ──► ssh ──► deploy-docker.sh
                                                                        │
                                              smoke tests vs live site ◄─┘
                                              └─ fails ⇒ roll back

weekly ─────────► CodeQL full · Trivy · Strix standard scan
```

Note the smoke tests appear twice: against the ephemeral stack pre-merge, and
against the live site post-deploy. Same file, different `BASE_URL`. That is the
point of taking the URL from the environment.
