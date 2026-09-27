# Plan — adding Strix to the CI/CD pipeline

Strix (`strix-agent`) is an autonomous AI pentesting agent. It is **DAST first**:
it runs the app, attacks it, and validates findings with a working
proof-of-concept — it is not a linter. It needs Docker on the runner, an LLM
API key, and money per run.

Tags: **[LAPTOP]** = your machine, **[GITHUB]** = repo settings / web UI,
**[CI]** = runs on the GitHub Actions runner.

---

## Where this lands in the current pipeline

```
today:    push master ──► deploy.yml ──► ssh ──► deploy-docker.sh ──► /health
                          (no security stage anywhere)

target:   PR / schedule ─► security.yml ─► strix quick|standard ─► report artifact
                                                                        │
          push master ──► deploy.yml ─────► ssh ──► deploy-docker.sh ────┘ (unchanged)
```

**`deploy.yml` is not modified.** The scan runs in its own workflow, on its own
triggers. Coupling a 5-to-40-minute pentest to the deploy path would make every
push wait on it for no benefit — a scan that finishes after the code is already
live has not blocked anything. Gating belongs at the **merge** step, not the
deploy step (Phase D).

---

## Four decisions made up front

### 1. Report-only first. Do not gate on day one.

Strix exits **2** when it finds vulnerabilities, which fails the job. This repo
is *known* vulnerable by design — verified, not guessed:

| Gap | Evidence |
|---|---|
| No authentication | no session/passport/auth middleware in `server.js` |
| No CSRF protection | `POST /users`, `/users/:id`, `/users/:id/delete` accept any origin |
| No security headers | `helmet` is not a dependency |
| No rate limiting | no `express-rate-limit` |

A gating scan on day one gives a permanently red pipeline that everyone learns
to ignore. Phase A runs with `continue-on-error: true` to produce a **baseline**.
You triage that baseline, fix or consciously accept each item, *then* flip the
gate on (Phase D).

### 2. Never point Strix at production.

`https://isdi-crud.duckdns.org` is a live, unauthenticated CRUD app with a
working `POST /users/:id/delete`. Strix has a shell, a browser and an exploit
runtime, and it *validates* findings by actually exploiting them. Pointed at
prod it will create, mutate and delete real rows, and the DuckDNS host resolves
to your EC2 instance.

The live target is always an **ephemeral copy** brought up inside the runner
from `docker-compose.yml` (Phase C). Production is never a scan target — not on
a schedule, not on dispatch.

### 3. Cost control is part of the design, not an afterthought.

The repo is public, so **GitHub Actions minutes are free**. The cost is entirely
the LLM key. Every invocation therefore carries `--max-budget`, and there is no
trigger on `push`.

| Mode | Runtime | Where it's used |
|---|---|---|
| `quick` | minutes | PRs / manual — diff-scoped automatically in CI |
| `standard` | ~30 min | weekly schedule |
| `deep` | 1–4 hrs | manual only, before a release |

### 4. You need a PR flow for the PR trigger to ever fire.

Right now there is one branch — `master` — and you push straight to it. A
`on: pull_request` workflow will **never run**. Two ways forward:

- **Recommended:** start branching (`git switch -c feature/x` → push → PR →
  merge). Costs you one extra command per change and unlocks Phase D gating,
  which is the whole point.
- **If you keep pushing to master:** drop the `pull_request` trigger and rely on
  `schedule` + `workflow_dispatch` only. Still useful, but nothing is ever
  blocked before it ships.

Phase A works either way, so this can be decided at Phase D.

---

## Prerequisites

**[LAPTOP]** — an LLM API key Strix can bill against. OpenRouter is the
documented default pick; any supported provider works.

**[GITHUB]** — two repository secrets, alongside the three deploy secrets you
already have:

```bash
gh secret set STRIX_LLM   --body "openrouter/z-ai/glm-5.3"
gh secret set LLM_API_KEY --body "sk-or-..."
gh secret list        # expect: EC2_HOST EC2_SSH_KEY EC2_USER LLM_API_KEY STRIX_LLM
```

`STRIX_LLM` is only a model name, not a credential — a repository **Variable**
would show its value in the UI and in logs. Secret is fine; just know the
distinction.

---

## Phase A — baseline code scan, report-only

Create `.github/workflows/security.yml`:

```yaml
name: Security Scan

on:
  workflow_dispatch:
  schedule:
    - cron: '0 3 * * 1'        # Mondays 03:00 UTC

concurrency:
  group: security-scan
  cancel-in-progress: false

jobs:
  strix:
    runs-on: ubuntu-latest
    timeout-minutes: 45         # a hung agent must not sit on a runner for hours

    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0        # required for diff-scope to resolve merge-base

      - name: Install Strix
        run: curl -sSL https://strix.ai/install | bash

      - name: Run scan
        id: scan
        continue-on-error: true  # PHASE A ONLY — remove at Phase D
        env:
          STRIX_LLM: ${{ secrets.STRIX_LLM }}
          LLM_API_KEY: ${{ secrets.LLM_API_KEY }}
        run: strix -n -t ./ --scan-mode quick --max-budget 5

      - name: Upload report
        if: always()
        uses: actions/upload-artifact@v4
        with:
          name: strix-report
          path: strix_runs/
          retention-days: 30

      - name: Outcome
        run: echo "scan step outcome: ${{ steps.scan.outcome }}"
```

Then **[LAPTOP]**:

```bash
git add .github/workflows/security.yml
git commit -m "Add Strix security scan workflow (report-only)"
git push
gh workflow run "Security Scan"
gh run watch
```

Download the artifact from the run page and read the findings. **Exit criterion:
a triaged list** — each finding marked fix / accept / false positive. Expect the
four gaps in the table above plus whatever else it turns up.

Notes:
- `--max-budget 5` caps spend at $5. In headless mode Strix stops *cleanly* at
  the cap and still writes a report, so a truncated scan is not a failed job.
  Raise it once you know what a real run costs.
- Exit codes: `0` clean, `1` execution error, `2` vulnerabilities found.
  `continue-on-error` swallows both 1 and 2, so read `steps.scan.outcome`
  rather than assuming a green job means a clean scan.

---

## Phase B — add the PR trigger

Once the baseline is triaged, add to `on:`:

```yaml
  pull_request:
```

In CI, Strix automatically scopes `quick` scans to changed files, which is why
`fetch-depth: 0` is already there. Force it explicitly if the auto-detection
misfires:

```yaml
        run: strix -n -t ./ --scan-mode quick --scope-mode diff --diff-base origin/master --max-budget 5
```

Still `continue-on-error`. This phase is about seeing PR-sized scans behave and
learning what they cost, not about blocking.

---

## Phase C — live DAST against an ephemeral stack

This is where Strix earns its keep. Code-only scanning is the weaker half; the
tool is built to run the app and attack it.

Add before the scan step:

```yaml
      - name: Start an ephemeral target
        run: |
          # Runner-local throwaway stack. BIND_ADDR is safe to open here —
          # the runner is destroyed when the job ends. On EC2 it must stay
          # 127.0.0.1, because Docker's iptables rules bypass the security group.
          BIND_ADDR=0.0.0.0 docker compose up -d --build
          for i in $(seq 1 30); do
            curl -sf http://127.0.0.1:3000/health && break
            sleep 3
          done
          curl -s http://127.0.0.1:3000/health
```

and give Strix both targets:

```yaml
        run: |
          strix -n \
            -t ./ \
            -t http://<TARGET_HOST>:3000 \
            --scan-mode quick \
            --max-budget 10 \
            --instruction "Express + MySQL CRUD app, no authentication by design. Focus on SQL injection in the search and :id routes, stored and reflected XSS in the EJS views, CSRF on the POST routes, and IDOR on /api/users/:id. The database is a throwaway container; destructive testing is in scope."
```

**Open question to settle by experiment, not assumption:** Strix runs its agent
inside its own Docker sandbox container, so `localhost` there is *the sandbox*,
not the runner. The runner host is normally reachable from a bridged container
at the docker0 gateway — typically `172.17.0.1`. Resolve it in the workflow
rather than hardcoding:

```yaml
      - name: Resolve the address the sandbox can reach
        run: |
          GW=$(ip -4 route show dev docker0 | awk '/src/ {print $NF}')
          echo "Gateway: $GW"
          docker run --rm curlimages/curl:latest -sf "http://$GW:3000/health" \
            && echo "reachable from a container" \
            || echo "NOT reachable — sandbox networking needs a different approach"
          echo "TARGET_HOST=$GW" >> "$GITHUB_ENV"
```

If that probe fails, fall back to Phase B (code-only) and raise it with the
Strix project — do not paper over it by pointing the scan at production.

The `--instruction` flag matters more than the scan mode here. Without it the
agent spends budget rediscovering that there is no login. Telling it the app is
deliberately unauthenticated redirects that spend at injection, XSS and IDOR.

---

## Phase D — turn on the gate

Only after the baseline is at zero-or-accepted.

1. Remove `continue-on-error: true` from the scan step. Exit 2 now fails the job.
2. **[GITHUB]** Settings → Branches → add a rule for `master`:
   - Require a pull request before merging
   - Require status checks to pass → select **Security Scan**
3. Stop pushing directly to `master`.

The gate is on **merge**, not on deploy. `deploy.yml` still fires on push to
master; it just can't be reached any more without passing the scan first.

---

## Risks and gotchas

| Risk | Handling |
|---|---|
| Scan hits production | Never a target. Ephemeral compose stack only (Phase C) |
| Runaway LLM spend | `--max-budget` on every call; no `push` trigger; weekly not nightly |
| Hung agent holds a runner | `timeout-minutes: 45` on the job |
| Permanently red pipeline | Report-only until the baseline is triaged (Phases A–C) |
| False sense of safety | `continue-on-error` makes a failed scan look green — read `steps.scan.outcome`, not the job colour |
| Findings leak in logs | Artifact is private to repo collaborators; the repo is **public**, so do not paste findings into issues before fixing |
| Strix edits local files | A local-directory target is mounted **live and writable** — the agent edits real files. Harmless on an ephemeral runner; **commit or stash first** if you ever run it on the laptop |
| First run is slow | It pulls the sandbox Docker image before starting |

---

## What this plan deliberately does not do

- **Does not touch `deploy.yml`.** The deploy path keeps working exactly as it
  does now throughout every phase.
- **Does not replace conventional tooling.** Strix is not a substitute for
  `npm audit` / Dependabot on the four dependencies, or for `gitleaks` on the
  history. Those are cheap, deterministic and fast; add them as separate steps
  if you want them. Strix is the expensive, non-deterministic layer on top.
- **Does not fix the four known gaps.** Auth, CSRF, helmet and rate limiting are
  application work, not pipeline work. The scan tells you what is there; it
  won't write the middleware.

---

## Order of work

1. Get an LLM API key, set the two secrets — *prerequisite*
2. Phase A: workflow, manual run, triage the baseline
3. Fix or formally accept each baseline finding
4. Phase B: PR trigger (requires adopting a branch/PR flow)
5. Phase C: ephemeral live target — settle the sandbox-networking probe first
6. Phase D: drop `continue-on-error`, add branch protection

Phases A and B are roughly an hour each. Phase C is the one with a real unknown
in it.

---

Sources: [Strix README](https://github.com/usestrix/strix),
[GitHub Actions integration](https://docs.strix.ai/integrations/github-actions),
[CI/CD integration](https://docs.strix.ai/integrations/ci-cd),
[CLI reference](https://docs.strix.ai/usage/cli).
