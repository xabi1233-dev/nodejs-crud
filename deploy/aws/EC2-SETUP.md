# Deploying to AWS EC2 with GitHub auto-deploy

The complete runbook, as actually performed on 2026-09-17.

```
your laptop  ──git push──►  GitHub  ──Actions SSH──►  EC2 instance
                                                        │
                                          nginx :80 ──► Node :3000 ──► MySQL
```

## Where each command runs

Every command block below is tagged. This is the single most common source of
confusion — the same command run in the wrong place fails in confusing ways.

| Tag | Prompt looks like | Run it on |
|---|---|---|
| **[LAPTOP]** | `zohaib@zohaib-ThinkPad-E15:...$` | Your machine |
| **[SERVER]** | `ubuntu@ip-172-31-28-250:...$` | The EC2 instance |

Quick rules of thumb:

- Contains `ssh`, the public IP, `gh`, or `/var/www/your_domain/crud` → **laptop**
- Contains `sudo systemctl`, `sudo apt`, or `/var/www/crud` → **server**
- Unsure? Run `whoami && hostname`. `zohaib` = laptop, `ubuntu` = server.

## This deployment's specifics

| Thing | Value |
|---|---|
| Public IP | `13.62.53.248` |
| Region | `eu-north-1` (Stockholm) |
| OS | Ubuntu 26.04 LTS ("resolute") |
| Instance | t3.micro, ~900 MB RAM |
| Repo | https://github.com/xabi1233-dev/nodejs-crud (public, branch `master`) |
| App path on server | `/var/www/crud` |
| SSH key | `~/.ssh/crud-key.pem` (admin), `~/.ssh/crud-deploy` (GitHub Actions) |

---

# Part 1 — Create the instance (AWS Console)

Browser work, no commands.

1. Pick your region in the top-right selector, and stay in it. Key pairs and
   security groups are region-scoped.
2. **EC2 → Instances → Launch instances**

   | Field | Value |
   |---|---|
   | Name | `crud-app` |
   | AMI | Ubuntu Server LTS (64-bit x86) |
   | Instance type | `t3.micro` |
   | Key pair | Create new → RSA → **.pem** → Download |
   | Storage | 8–16 GiB gp3 |

3. **Edit** the Network settings → create security group with exactly two rules:

   | Type | Port | Source |
   |---|---|---|
   | SSH | 22 | **My IP** |
   | HTTP | 80 | Anywhere `0.0.0.0/0` |

4. **Launch**, wait for *Running* + 2/2 status checks, copy the **Public IPv4**.

> **Do not open port 3000.** Node listens only on `127.0.0.1`; nginx is the sole
> public entry point. Opening 3000 would let traffic bypass it entirely.
>
> **The .pem downloads once.** Lose it and you lose access to that instance —
> there is no re-download.

---

# Part 2 — Connect

**[LAPTOP]**

```bash
mv ~/Downloads/your-key.pem ~/.ssh/crud-key.pem
chmod 400 ~/.ssh/crud-key.pem
ssh -i ~/.ssh/crud-key.pem ubuntu@13.62.53.248
```

`chmod 400` is mandatory — SSH refuses keys that others can read.

You are now on the server. Everything in Parts 3, 5, 6 and 7 runs here.

---

# Part 3 — Install the software

**[SERVER]**

```bash
sudo apt update
sudo apt install -y nginx git nodejs npm mysql-server
node -v && npm -v && nginx -v
```

Expect Node **v22.x**. Ubuntu 26.04 is too new for NodeSource, but its own
repos carry Node 22 LTS at `/usr/bin/node` — which is what the systemd unit
expects. Nothing third-party needed.

Check nginx is serving: visit `http://13.62.53.248` and you should see
**"Welcome to nginx!"**.

### Add swap

**[SERVER]**

With ~900 MB RAM and MySQL taking ~500 MB of it, `npm install` can be starved.

```bash
sudo fallocate -l 1G /swapfile
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
free -h
```

The `fstab` line makes it survive reboots.

---

# Part 4 — Push the code to GitHub

**[LAPTOP]**

```bash
cd /var/www/your_domain/crud
git init -b master
git add .
git status --short
```

**Check that `.env` and `node_modules/` are NOT listed** before committing.
Getting a secret out of Git history after pushing is painful.

```bash
git commit -m "Node.js CRUD app"
gh repo create nodejs-crud --public --source=. --remote=origin --push
```

> Never commit real passwords — not even in `.env.example`, which is a template
> and gets committed by design. Use a placeholder there.

---

# Part 5 — Deploy the app

**[SERVER]**

```bash
sudo git clone https://github.com/xabi1233-dev/nodejs-crud.git /var/www/crud
sudo chown -R ubuntu:ubuntu /var/www/crud
cd /var/www/crud
npm install --omit=dev
ls node_modules | wc -l
```

That count should be ~86, not 0. `node_modules` is never committed — it is
rebuilt here so native modules match the server's architecture.

### Database

**[SERVER]**

```bash
sudo mysql < /var/www/crud/schema.sql
sudo mysql -e "ALTER USER 'crud_user'@'localhost' IDENTIFIED BY 'YourStrongPass#2026';"
```

`sudo mysql` needs no password here: on a fresh Ubuntu server MySQL root uses the
`auth_socket` plugin. (This is *not* true on the local dev laptop, which needs
`sudo mysql --defaults-file=/etc/mysql/debian.cnf`.)

Verify:

```bash
mysql -u crud_user -p'YourStrongPass#2026' crud_db -e "SELECT id, name, email FROM users;"
```

### Environment file

**[SERVER]**

```bash
cat > /var/www/crud/.env <<'ENV'
PORT=3000
DB_HOST=127.0.0.1
DB_PORT=3306
DB_USER=crud_user
DB_PASSWORD="YourStrongPass#2026"
DB_NAME=crud_db
ENV

chmod 600 /var/www/crud/.env
```

`.env` is gitignored, so it never reaches GitHub and is never overwritten by a
deploy. It must be created on each new server by hand.

---

# Part 6 — Run it as a service

**[SERVER]**

```bash
sudo cp /var/www/crud/deploy/aws/crud.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now crud
systemctl status crud --no-pager
curl http://127.0.0.1:3000/health
```

Expect `Active: active (running)` and `{"ok":true,"db":"up"}`.

`enable` makes it start at boot; `--now` starts it immediately. From here the app
survives logout, disconnection and reboot — you never need `node server.js` again.

If it fails: `journalctl -u crud -n 30 --no-pager`

---

# Part 7 — Point nginx at the app

**[SERVER]**

```bash
sudo cp /var/www/crud/deploy/aws/nginx-crud.conf /etc/nginx/sites-available/crud
sudo ln -sf /etc/nginx/sites-available/crud /etc/nginx/sites-enabled/crud
sudo rm -f /etc/nginx/sites-enabled/default
sudo nginx -t
sudo systemctl reload nginx
```

`nginx -t` must print `test is successful` before reloading. Removing the
`default` site matters: both it and ours claim `default_server` on port 80, and
nginx refuses to start with that conflict.

**The app is now live at http://13.62.53.248**

---

# Part 8 — GitHub auto-deploy

## 8.1 Create a deploy key

**[LAPTOP]**

```bash
ssh-keygen -t ed25519 -f ~/.ssh/crud-deploy -N "" -C "github-actions-deploy"
```

Separate from your admin key, so GitHub's access can be revoked independently.

## 8.2 Authorize it on the server

**[LAPTOP]** — note this runs locally even though it modifies the server:

```bash
ssh -i ~/.ssh/crud-key.pem ubuntu@13.62.53.248 'echo "" >> ~/.ssh/authorized_keys'
cat ~/.ssh/crud-deploy.pub | ssh -i ~/.ssh/crud-key.pem ubuntu@13.62.53.248 'cat >> ~/.ssh/authorized_keys'
ssh -i ~/.ssh/crud-key.pem ubuntu@13.62.53.248 'ssh-keygen -lf ~/.ssh/authorized_keys'
```

That first line is not optional: if `authorized_keys` lacks a trailing newline,
the appended key fuses onto the previous line and **both** keys break.

Expect two fingerprints. Then test the new key alone:

```bash
ssh -i ~/.ssh/crud-deploy ubuntu@13.62.53.248 'echo deploy key works'
```

> `ssh-copy-id -o IdentityFile=~/...` does **not** work — ssh doesn't expand `~`
> inside `-o` values. Use the append method above.

## 8.3 Store the secrets

**[LAPTOP]**

```bash
cd /var/www/your_domain/crud
gh secret set EC2_SSH_KEY < ~/.ssh/crud-deploy
gh secret set EC2_HOST --body "13.62.53.248"
gh secret set EC2_USER --body "ubuntu"
gh secret list
```

`EC2_SSH_KEY` takes the **private** key (no `.pub`).

## 8.4 Ship the workflow

**[LAPTOP]**

```bash
git add -A
git commit -m "Add GitHub Actions auto-deploy"
git push
```

**[LAPTOP]** — one manual pull, because the workflow runs `deploy.sh` *on the
server* and the server doesn't have that file yet:

```bash
ssh -i ~/.ssh/crud-key.pem ubuntu@13.62.53.248 'cd /var/www/crud && git pull'
```

## 8.5 Test

**[LAPTOP]**

```bash
gh workflow run "Deploy to EC2"
gh run list --limit 3
```

---

# How the auto-deploy actually works

Three files cooperate:

| File | Lives on | Role |
|---|---|---|
| `.github/workflows/deploy.yml` | GitHub | The trigger and the instructions |
| `deploy/aws/deploy.sh` | The EC2 server | The actual update work |
| `~/.ssh/crud-deploy` | Laptop + GitHub secret | The key that lets GitHub in |

## Step by step, on every push

**1. GitHub notices.** The workflow declares:

```yaml
on:
  push:
    branches: [master]
```

A push to `master` matches, so GitHub fires the workflow.

**2. GitHub rents a temporary computer.** `runs-on: ubuntu-latest` boots a fresh,
empty VM — the *runner*. The deploy is not run by your laptop or by your server:
it is a third machine that exists for ~15 seconds and is then destroyed. Your
laptop can be switched off the whole time.

**3. The runner is given a key.** It starts with no access to anything. The first
step writes the private key out of GitHub's encrypted secret storage:

```yaml
printf '%s\n' "$SSH_KEY" > ~/.ssh/deploy_key
chmod 600 ~/.ssh/deploy_key
```

This is why `EC2_SSH_KEY` must be the **private** key — it is the runner proving
its identity. The matching public key sits in `~/.ssh/authorized_keys` on the
server (Part 8.2).

**4. The runner SSHes in and issues one command:**

```bash
ssh -i ~/.ssh/deploy_key ubuntu@13.62.53.248 'bash /var/www/crud/deploy/aws/deploy.sh'
```

No files are copied. The runner simply tells the server to update itself.

**5. The server pulls from GitHub.** `deploy.sh` does the real work:

```
git fetch origin master
git reset --hard origin/master      ← files updated
npm install                          ← only if package.json changed
sudo systemctl restart crud          ← Node reloads the new code
poll /health for 20s                 ← did it come back up?
```

The restart is required because Node loads code into memory once at startup.
New files on disk change nothing until the process restarts. (PHP re-reads files
per request, which is why Apache sites update instantly and this one does not.)

**6. Verification.** The workflow curls the public URL. If `/health` never returns
200, the run goes red and dumps the service logs into the run output.

## The mental model

```
laptop ──push──► GitHub ──"go update yourself"──► EC2 ──pull──► GitHub
```

Code travels laptop → GitHub → server. The *instruction* travels GitHub → server.
**The server pulls its own code**; GitHub never pushes files to it.

Two consequences follow from that:

- The server needs no GitHub credentials, because the repo is public and it only
  ever reads.
- `deploy.sh` must already exist on the server before the first automated run —
  hence the one manual `git pull` in Part 8.4.

## Why it fails safe

A failed deploy does not take the site down. `git reset --hard` and the restart
happen on a server that is already serving; if the new code won't boot, systemd
keeps retrying while the health poll fails and marks the run red. You get a red X
and an email, and the site continues serving whatever was last working.

---

# Daily workflow

**[LAPTOP]** — this is all you do from now on:

```bash
cd /var/www/your_domain/crud
# edit code
git commit -am "what changed"
git push
```

The site updates within ~30 seconds. Watching is optional:

```bash
gh run watch              # follow the current deploy
gh run list --limit 3     # recent deploys
gh run view --log-failed  # why the last one broke
```

### What a deploy does

`.github/workflows/deploy.yml` SSHes in and runs `deploy/aws/deploy.sh`, which:
fetches, hard-resets to `origin/master`, reinstalls dependencies **only if
`package.json` changed**, restarts the service, then polls `/health` for 20s.
On failure it dumps the service logs and marks the run red — and the site keeps
serving the previous version rather than going down.

> **Never edit files directly on the server.** `deploy.sh` runs
> `git reset --hard`, so server-side edits are wiped on the next deploy.
> The repo is the single source of truth.

---

# Operations

**[SERVER]**

```bash
systemctl status crud                       # is the app up
journalctl -u crud -f                       # live app logs
sudo systemctl restart crud                 # restart
sudo tail -f /var/log/nginx/crud_error.log  # nginx errors
sudo nginx -t && sudo systemctl reload nginx

mysql -u crud_user -p crud_db -e "SELECT * FROM users;"
```

# Troubleshooting

| Symptom | Cause and fix |
|---|---|
| Browser times out | Security group missing the HTTP :80 rule |
| Connection **refused** on :80 | SG is fine, nothing listening — nginx is down |
| **502 Bad Gateway** | nginx up, Node down → `systemctl status crud` |
| `EADDRINUSE` on :3000 | A manual `node server.js` still running → `pkill -f "node server.js"`. Ctrl+Z only suspends; use **Ctrl+C** |
| `Cannot find module` | `npm install --omit=dev` was skipped |
| SSH `Permission denied (publickey)` | Wrong user (it's `ubuntu`), or key not `chmod 400`, or key not in `authorized_keys` |
| SSH hangs | Your IP changed → update the SG's SSH source |
| Actions run fails | `gh run view --log-failed` |
| 500 errors | DB problem → `journalctl -u crud -n 50` |

# Cost

~$8–9/month for t3.micro plus storage in `eu-north-1`. Against $100 of credit,
roughly 11–12 months of continuous running.

- Set a budget alert: **Billing → Budgets → Create budget**
- **Stopped** instance: storage only (~$0.65/mo), but the public IP is released —
  you'd have to update the `EC2_HOST` secret
- **Terminate** when finished; stopped instances still bill for their volume

# Not done — needed before this is production

Deliberately minimal: plain HTTP, no auth on the CRUD pages, anyone with the IP
can add or delete users, and the data lives in exactly one place.

1. Domain + HTTPS (certbot — free, ~10 minutes, biggest single win)
2. Authentication
3. CSRF protection on mutating routes
4. Automated MySQL backups
