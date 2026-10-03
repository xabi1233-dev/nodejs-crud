#!/bin/bash
#
# Cloud-init user_data — rebuilds the whole stack on a fresh instance.
#
# Runs ONCE, as root, on first boot. Terraform fills the $${...} placeholders
# via templatefile(). Watch it live with:
#
# (That doubled dollar above is an escape: templatefile() parses EVERY $${...}
# in this file, comments included, so a literal one has to be written $$ to
# survive. A stray $${foo} in a comment is a hard template error.)
#
#   sudo tail -f /var/log/cloud-init-output.log
#
# IMPORTANT: this reproduces INFRASTRUCTURE AND CONFIG, not DATA. The MySQL
# volume is new, so the database starts from schema.sql's three seed rows.
# Anything users added before the destroy is gone. Back up first if it matters.

set -euxo pipefail

APP_DIR=/var/www/crud

# --- 0. Swap -----------------------------------------------------------------
# t3.micro has ~1 GB RAM. MySQL 8 plus a Node build does not fit, and the OOM
# killer takes MySQL first. fstab entry keeps it across reboots.
if [ ! -f /swapfile ]; then
  fallocate -l 2G /swapfile
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

# --- 1. Packages -------------------------------------------------------------
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y git nginx curl ca-certificates

# Docker's official script; includes the compose plugin. Ubuntu's own docker.io
# package lags badly and ships no compose.
curl -fsSL https://get.docker.com | sh
usermod -aG docker ubuntu
systemctl enable --now docker

# --- 2. Application ----------------------------------------------------------
# /var/www/crud, NOT /home/ubuntu/app: deploy/aws/deploy-docker.sh and the
# GitHub Actions workflow both hardcode this path. Change it here and
# auto-deploy silently breaks after the next rebuild.
mkdir -p /var/www
git clone ${repo_url} "$APP_DIR"
chown -R ubuntu:ubuntu "$APP_DIR"

# --- 3. Production secrets ---------------------------------------------------
# .env.docker is gitignored, so it is NOT in the clone. Without it, compose
# falls back to the defaults in docker-compose.yml — including
# BIND_ADDR=0.0.0.0, which would publish port 3000 on the public interface.
#
# That is not merely untidy: Docker writes its own iptables rules that BYPASS
# the AWS security group, so the app would be reachable on :3000 from the
# internet, around nginx and around TLS.
#
# Passwords are generated fresh on every rebuild. Nothing needs to remember
# them, because the database volume is new too.
umask 077
cat > "$APP_DIR/.env.docker" <<EOF
MYSQL_ROOT_PASSWORD=$(openssl rand -base64 24 | tr -d '/+=' | cut -c1-24)
MYSQL_PASSWORD=$(openssl rand -base64 24 | tr -d '/+=' | cut -c1-24)
BIND_ADDR=127.0.0.1
EOF
chown ubuntu:ubuntu "$APP_DIR/.env.docker"
chmod 600 "$APP_DIR/.env.docker"
umask 022

# --- 4. Start the containers -------------------------------------------------
cd "$APP_DIR"
docker compose --env-file .env.docker up -d --build

# Wait for the app to answer before putting nginx in front of it.
for i in $(seq 1 40); do
  if curl -sf http://127.0.0.1:3000/health > /dev/null; then
    echo "app healthy after $i attempts"
    break
  fi
  sleep 5
done

# --- 5. GitHub Actions deploy key -------------------------------------------
# Without this, the first push after a rebuild fails with Permission denied
# (publickey) — the workflow SSHes in with a dedicated key.
#
# Appended on its own line: a missing trailing newline in authorized_keys
# fuses this onto the previous entry and silently invalidates both.
if [ -n "${deploy_public_key}" ]; then
  install -d -m 700 -o ubuntu -g ubuntu /home/ubuntu/.ssh
  touch /home/ubuntu/.ssh/authorized_keys
  echo "" >> /home/ubuntu/.ssh/authorized_keys
  echo "${deploy_public_key}" >> /home/ubuntu/.ssh/authorized_keys
  chown ubuntu:ubuntu /home/ubuntu/.ssh/authorized_keys
  chmod 600 /home/ubuntu/.ssh/authorized_keys
fi

# --- 6. DuckDNS --------------------------------------------------------------
# A rebuild means a new public IP. The domain must be repointed before certbot
# can validate it, so this runs the updater immediately, then installs the cron.
if [ -n "${duckdns_token}" ]; then
  cat > /etc/duckdns.conf <<EOF
DUCKDNS_DOMAIN=${duckdns_domain}
DUCKDNS_TOKEN=${duckdns_token}
EOF
  chmod 600 /etc/duckdns.conf
  chown root:root /etc/duckdns.conf

  install -d -m 755 /var/lib/duckdns
  bash "$APP_DIR/deploy/aws/duckdns-update.sh" || echo "duckdns update failed, continuing"

  cp "$APP_DIR/deploy/aws/duckdns.cron" /etc/cron.d/duckdns
  chmod 644 /etc/cron.d/duckdns
  chown root:root /etc/cron.d/duckdns

  # DNS needs a moment to propagate before certbot asks Let's Encrypt to
  # resolve the name.
  sleep 30
fi

# --- 7. nginx ----------------------------------------------------------------
cp "$APP_DIR/deploy/aws/nginx-crud.conf" /etc/nginx/sites-available/crud

# Only rewrite server_name when there IS a domain. With an empty
# duckdns_domain — the scratch default — this sed would otherwise produce
# `server_name .duckdns.org;`, which matches nothing you would ever request.
# Leaving the stock `server_name _;` makes the block match any Host, which is
# exactly what you want when testing against a bare IP.
if [ -n "${duckdns_domain}" ]; then
  sed -i "s/server_name _;/server_name ${duckdns_domain}.duckdns.org;/" \
    /etc/nginx/sites-available/crud
fi
ln -sf /etc/nginx/sites-available/crud /etc/nginx/sites-enabled/crud
rm -f /etc/nginx/sites-enabled/default
nginx -t
systemctl enable --now nginx
systemctl reload nginx

# --- 8. TLS ------------------------------------------------------------------
# Let's Encrypt allows only 5 certificates per domain per week. A
# destroy/apply loop burns through that in a single afternoon and then issues
# nothing for days — so staging is the default. Staging certs are untrusted by
# browsers (expect a warning); that is the point, they are free and unlimited.
#
# Set certbot_staging = false in terraform.tfvars for a real certificate, and
# only when you are done iterating.
if [ -n "${duckdns_token}" ]; then
  apt-get install -y certbot python3-certbot-nginx

  STAGING_FLAG=""
  if [ "${certbot_staging}" = "true" ]; then
    STAGING_FLAG="--staging"
  fi

  certbot --nginx $STAGING_FLAG \
    -d "${duckdns_domain}.duckdns.org" \
    --non-interactive --agree-tos \
    -m "${certbot_email}" \
    --redirect || echo "certbot failed; site remains on HTTP"
fi

echo "user_data finished: https://${duckdns_domain}.duckdns.org should be live"
