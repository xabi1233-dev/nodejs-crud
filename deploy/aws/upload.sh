#!/usr/bin/env bash
#
# Packages the app and uploads it to the EC2 instance, then optionally runs
# the provisioning script.
#
# Run LOCALLY from the project root:
#   bash deploy/aws/upload.sh <ec2-public-ip> ~/.ssh/crud-key.pem
#
# Re-run this any time you change code to redeploy.

set -euo pipefail

EC2_IP="${1:-}"
KEY="${2:-$HOME/.ssh/crud-key.pem}"
REMOTE_USER=ubuntu

if [[ -z $EC2_IP ]]; then
  echo "Usage: bash deploy/aws/upload.sh <ec2-public-ip> [path/to/key.pem]" >&2
  exit 1
fi

if [[ ! -f $KEY ]]; then
  echo "SSH key not found: $KEY" >&2
  exit 1
fi

# AWS refuses keys that are group/world readable.
chmod 400 "$KEY"

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SSH_OPTS=(-i "$KEY" -o StrictHostKeyChecking=accept-new)

log() { printf '\n\033[1;34m==> %s\033[0m\n' "$1"; }

log "Syncing app to ${REMOTE_USER}@${EC2_IP}:~/crud"

# node_modules is rebuilt on the server (native modules must match its arch).
# .env is excluded: the server has its own with a generated DB password.
rsync -az --delete \
  --exclude node_modules \
  --exclude .env \
  --exclude .git \
  --exclude 'npm-debug.log*' \
  -e "ssh ${SSH_OPTS[*]}" \
  "$SRC_DIR/" "${REMOTE_USER}@${EC2_IP}:~/crud/"

log "Upload complete"

read -rp "Run provisioning on the server now? [y/N] " answer
if [[ ${answer,,} == y ]]; then
  log "Running provision.sh on the instance (this takes a few minutes)"
  ssh "${SSH_OPTS[@]}" "${REMOTE_USER}@${EC2_IP}" \
    'cd ~/crud && bash deploy/aws/provision.sh'
else
  cat <<NEXT

Skipped. To provision manually:

  ssh -i $KEY ${REMOTE_USER}@${EC2_IP}
  cd ~/crud && bash deploy/aws/provision.sh

For a code-only redeploy (already provisioned):

  ssh -i $KEY ${REMOTE_USER}@${EC2_IP} \\
    'sudo rsync -a --delete --exclude node_modules --exclude .env ~/crud/ /var/www/crud/ && \\
     cd /var/www/crud && npm install --omit=dev && sudo systemctl restart crud'

NEXT
fi
