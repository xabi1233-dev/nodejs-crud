# Moving the EC2 deployment into containers

Replaces the native setup (systemd + host MySQL) with the same compose stack
that runs on the laptop. nginx **stays on the host** — it holds the Let's
Encrypt certificate and remains the only public entry point.

```
before:  internet → nginx :443/:80 → systemd node :3000 → host MySQL
after:   internet → nginx :443/:80 → container app :3000 → container MySQL
                                     └── both on 127.0.0.1, not public ──┘
```

Tags: **[LAPTOP]** = your machine, **[SERVER]** = the EC2 instance.

> **This migration moves live data.** Part 2 takes a backup first and Part 8
> keeps the old setup recoverable. Read to the end before starting.

---

## Part 1 — Check there is room

**[SERVER]**

```bash
df -h /
free -h
```

Docker needs roughly **1.5 GB** of disk for the images (`mysql:8.4` is ~600 MB,
`node:22-alpine` plus dependencies ~250 MB, your two built images on top).
If less than 2.5 GB is free, grow the EBS volume before continuing — running
out of disk mid-migration is a bad place to be.

RAM is the tighter constraint: ~900 MB total. This works only because the host
MySQL is stopped in Part 3, freeing the ~500 MB it holds.

---

## Part 2 — Back up the database

**[SERVER]** — do this even if you think the data doesn't matter.

```bash
mysqldump -u crud_user -p crud_db > ~/crud_backup_$(date +%F).sql
ls -lh ~/crud_backup_*.sql
head -5 ~/crud_backup_*.sql
```

Enter the password from `/var/www/crud/.env`. The file should be non-empty and
start with MySQL comments. Copy it off the instance too:

**[LAPTOP]**

```bash
scp -i ~/.ssh/crud-key.pem ubuntu@13.62.53.248:~/crud_backup_*.sql ./
```

---

## Part 3 — Stop the native stack

**[SERVER]**

```bash
sudo systemctl stop crud
sudo systemctl disable crud

sudo systemctl stop mysql
sudo systemctl disable mysql

free -h
ss -ltn | grep 3000 || echo "port 3000 free"
```

The site is **down from here until Part 6.** Both services are disabled so they
cannot come back at reboot and fight the containers for port 3000.

`disable` does not uninstall anything — the host MySQL data stays on disk, which
is what makes Part 8's rollback possible.

---

## Part 4 — Install Docker

**[SERVER]** — Docker's official repository, not the Ubuntu package, which lags
badly and lacks the compose plugin:

```bash
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker ubuntu
newgrp docker

docker --version
docker compose version
```

`newgrp docker` applies the group to the current shell. New SSH sessions get it
automatically.

Unlike the laptop, this is plain Docker Engine — no Docker Desktop, no VM, so
bind mounts from any path work normally here.

---

## Part 5 — Production credentials

**[SERVER]** — the compose file's defaults are local throwaway values. Generate
real ones:

```bash
cd /var/www/crud

cat > .env.docker <<EOF
MYSQL_ROOT_PASSWORD=$(openssl rand -base64 24 | tr -d '/+=' | cut -c1-24)
MYSQL_PASSWORD=$(openssl rand -base64 24 | tr -d '/+=' | cut -c1-24)
BIND_ADDR=127.0.0.1
EOF

chmod 600 .env.docker
cat .env.docker
```

Two things this file does:

- supplies real passwords, so the committed defaults are never used in production
- sets `BIND_ADDR=127.0.0.1`, publishing the app **only on loopback**. Without
  it Docker would bind `0.0.0.0:3000` and — because Docker writes its own
  iptables rules that bypass the security group — expose the app directly on
  port 3000, around nginx and around HTTPS.

`.env.docker` is untracked, so `git reset --hard` during a deploy leaves it
alone. It exists only on the server; back it up somewhere safe.

---

## Part 6 — Start the stack

**[SERVER]**

```bash
cd /var/www/crud
git pull
docker compose --env-file .env.docker up -d --build
```

First run takes several minutes — it pulls base images and builds both. Then:

```bash
docker compose ps
curl http://127.0.0.1:3000/health
```

Both containers should be `Up` and `(healthy)`, and health returns
`{"ok":true,"db":"up"}`.

Your site should now respond again over HTTPS — nginx already proxies to
`127.0.0.1:3000` and neither it nor the certificate was touched.

At this point the database contains only `schema.sql`'s three seed rows. Real
data comes next.

---

## Part 7 — Restore your data

**[SERVER]**

```bash
docker compose --env-file .env.docker exec -T db \
  mysql -u root -p"$(grep MYSQL_ROOT_PASSWORD .env.docker | cut -d= -f2)" crud_db \
  < ~/crud_backup_*.sql
```

`exec -T` disables TTY allocation, which is required when piping a file in.

The dump contains `DROP TABLE` / `CREATE TABLE`, so it replaces the seed rows
with your real ones. Verify through the app rather than the database:

```bash
curl -s http://127.0.0.1:3000/api/users
```

Then load the site in a browser and confirm your records are there.

---

## Part 8 — Rollback, if needed

Nothing was deleted, so reverting is quick:

```bash
cd /var/www/crud
docker compose --env-file .env.docker down

sudo systemctl enable --now mysql
sudo systemctl enable --now crud
curl http://127.0.0.1:3000/health
```

The host MySQL still holds the data as it was at Part 2. Add `-v` to the `down`
only once you are confident — that deletes the container database permanently.

---

## Part 9 — Switch auto-deploy to containers

Your GitHub Actions workflow still calls `deploy.sh`, which restarts a systemd
service that no longer exists.

**[LAPTOP]** — edit `.github/workflows/deploy.yml`:

```yaml
            'bash /var/www/crud/deploy/aws/deploy-docker.sh'
```

(replacing `deploy.sh`), then:

```bash
git add -A
git commit -m "Switch EC2 auto-deploy to containers"
git push
```

`deploy-docker.sh` pulls, rebuilds the images, restarts the stack, polls
`/health`, and prunes superseded image layers — that last step matters on a
small root volume, since every rebuild otherwise leaves the old image behind.

Verify with `gh run watch`.

---

## Operating the containers

**[SERVER]** — all from `/var/www/crud`:

```bash
docker compose --env-file .env.docker ps
docker compose --env-file .env.docker logs -f app
docker compose --env-file .env.docker restart app
docker compose --env-file .env.docker down          # stop, keep data
docker compose --env-file .env.docker up -d --build # rebuild after changes

# database shell
docker compose --env-file .env.docker exec db mysql -u root -p crud_db

# backup (now that MySQL is in a container)
docker compose --env-file .env.docker exec -T db \
  mysqldump -u root -p"$(grep MYSQL_ROOT_PASSWORD .env.docker | cut -d= -f2)" \
  crud_db > ~/backup_$(date +%F).sql
```

Typing `--env-file .env.docker` every time is tedious; add an alias:

```bash
echo "alias dc='docker compose --env-file /var/www/crud/.env.docker'" >> ~/.bashrc
source ~/.bashrc
```

### Starting at boot

`restart: unless-stopped` plus Docker's own service being enabled means the
stack returns after a reboot. Confirm once:

```bash
sudo systemctl is-enabled docker
sudo reboot
# wait ~60s, reconnect
docker compose --env-file /var/www/crud/.env.docker ps
```

---

## Troubleshooting

| Symptom | Cause |
|---|---|
| **502** from nginx | Containers down, or `BIND_ADDR` not `127.0.0.1` so nothing is on loopback |
| App container restarts in a loop | Wrong DB password → `logs app`. If `.env.docker` changed after the volume was created, the old password persists inside the volume |
| `db` never becomes healthy | Usually out of memory → `free -h`, `docker compose logs db` |
| Build fails, "no space left" | `df -h /`, then `docker system prune -a` |
| Port 3000 in use | The native service came back → `sudo systemctl disable --now crud` |
| Data missing after deploy | Normal only if the volume was wiped with `down -v`; restore from the Part 2 dump |

## What did not change

nginx, the Let's Encrypt certificate and its renewal timer, the DuckDNS cron,
and the security group are all untouched and still host-level. Only what sits
behind `127.0.0.1:3000` changed.
