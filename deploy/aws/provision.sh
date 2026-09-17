#!/usr/bin/env bash
#
# Provisions a fresh Ubuntu EC2 instance to run the CRUD app:
#   Node.js 20 + MySQL 8 + Nginx reverse proxy + systemd service
#
# Run ON THE EC2 INSTANCE, from the uploaded app directory:
#   cd ~/crud && bash deploy/aws/provision.sh
#
# Safe to re-run: every step is idempotent.

set -euo pipefail

APP_DIR=/var/www/crud
APP_USER=ubuntu
DB_NAME=crud_db
DB_USER=crud_user

log() { printf '\n\033[1;34m==> %s\033[0m\n' "$1"; }

if [[ $EUID -eq 0 ]]; then
  echo "Run this as the 'ubuntu' user, not root. It will sudo where needed." >&2
  exit 1
fi

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# --- 1. System packages ----------------------------------------------------

log "Updating package lists"
sudo apt-get update -qq

log "Installing Node.js"
# Prefer Ubuntu's own package when it ships Node 20+. NodeSource does not
# publish repos for every codename (Ubuntu 26.04 "resolute" has none), and the
# distro package is a supported LTS anyway.
if ! command -v node >/dev/null; then
  NODE_CANDIDATE="$(apt-cache policy nodejs | awk '/Candidate:/{print $2}')"
  NODE_MAJOR="${NODE_CANDIDATE%%.*}"
  if [[ $NODE_MAJOR =~ ^[0-9]+$ ]] && (( NODE_MAJOR >= 20 )); then
    echo "using distro nodejs ${NODE_CANDIDATE}"
    sudo apt-get install -y nodejs npm
  else
    echo "distro nodejs too old (${NODE_CANDIDATE:-none}), using NodeSource"
    curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
    sudo apt-get install -y nodejs
  fi
fi
node -v
npm -v

log "Installing MySQL server and Nginx"
sudo apt-get install -y mysql-server nginx

# --- 2. Swap (t3.micro has only 1 GB RAM; MySQL + Node is tight) -----------

log "Ensuring 1 GB swap exists"
# t3.micro has ~900 MB RAM and the root volume may only be 8 GB, so keep the
# swapfile modest — it exists to absorb the npm install / MySQL startup spike.
if ! sudo swapon --show | grep -q /swapfile; then
  sudo fallocate -l 1G /swapfile
  sudo chmod 600 /swapfile
  sudo mkswap /swapfile
  sudo swapon /swapfile
  grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
else
  echo "swap already configured"
fi

# --- 3. Database -----------------------------------------------------------

log "Creating database and application user"

# On Ubuntu, root@localhost uses auth_socket, so `sudo mysql` works without
# a password. Generate a strong DB password once and reuse it on re-runs.
PW_FILE=/home/$APP_USER/.crud_db_password
if [[ -f $PW_FILE ]]; then
  DB_PASS="$(sudo cat "$PW_FILE")"
  echo "reusing existing database password from $PW_FILE"
else
  # Alphanumeric plus a fixed special char keeps it shell- and .env-safe
  # while still satisfying any validate_password policy.
  DB_PASS="$(openssl rand -base64 24 | tr -d '/+=' | cut -c1-20)aA1#"
  echo "$DB_PASS" | sudo tee "$PW_FILE" >/dev/null
  sudo chown "$APP_USER:$APP_USER" "$PW_FILE"
  sudo chmod 600 "$PW_FILE"
  echo "generated new database password, saved to $PW_FILE"
fi

sudo mysql <<SQL
CREATE DATABASE IF NOT EXISTS ${DB_NAME}
  CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
ALTER USER '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
SQL

log "Applying schema"
# Strip the CREATE USER lines from schema.sql; the user is created above with
# the generated password instead of the local development one.
sed '/CREATE USER/d; /GRANT ALL/d; /FLUSH PRIVILEGES/d' "$SRC_DIR/schema.sql" \
  | sudo mysql "$DB_NAME"

# --- 4. Application files --------------------------------------------------

log "Installing application to $APP_DIR"
sudo mkdir -p "$APP_DIR"
sudo rsync -a --delete \
  --exclude node_modules --exclude .env --exclude .git \
  "$SRC_DIR/" "$APP_DIR/"
sudo chown -R "$APP_USER:$APP_USER" "$APP_DIR"

log "Writing production .env"
sudo -u "$APP_USER" tee "$APP_DIR/.env" >/dev/null <<ENV
PORT=3000
DB_HOST=127.0.0.1
DB_PORT=3306
DB_USER=${DB_USER}
DB_PASSWORD="${DB_PASS}"
DB_NAME=${DB_NAME}
ENV
sudo chmod 600 "$APP_DIR/.env"

log "Installing npm dependencies (production only)"
cd "$APP_DIR"
sudo -u "$APP_USER" npm install --omit=dev --no-audit --no-fund

# --- 5. systemd service ----------------------------------------------------

log "Installing systemd service"
sudo cp "$APP_DIR/deploy/aws/crud.service" /etc/systemd/system/crud.service
sudo systemctl daemon-reload
sudo systemctl enable crud
sudo systemctl restart crud

# --- 6. Nginx --------------------------------------------------------------

log "Configuring Nginx"
sudo cp "$APP_DIR/deploy/aws/nginx-crud.conf" /etc/nginx/sites-available/crud
sudo ln -sf /etc/nginx/sites-available/crud /etc/nginx/sites-enabled/crud
# Remove the stock default site so ours owns port 80.
sudo rm -f /etc/nginx/sites-enabled/default
sudo nginx -t
sudo systemctl reload nginx

# --- 7. Verify -------------------------------------------------------------

log "Verifying"
sleep 2
echo -n "node direct  : "; curl -s -m 5 http://127.0.0.1:3000/health || echo "FAILED"
echo
echo -n "through nginx: "; curl -s -m 5 http://127.0.0.1/health || echo "FAILED"
echo

PUBLIC_IP="$(curl -s -m 5 http://169.254.169.254/latest/meta-data/public-ipv4 || echo '<your-ec2-ip>')"

cat <<DONE

------------------------------------------------------------
Done.

  App URL      : http://${PUBLIC_IP}
  DB password  : stored in ${PW_FILE}

  Service      : sudo systemctl status crud
  App logs     : journalctl -u crud -f
  Nginx logs   : sudo tail -f /var/log/nginx/crud_error.log
  Restart app  : sudo systemctl restart crud
------------------------------------------------------------
DONE
