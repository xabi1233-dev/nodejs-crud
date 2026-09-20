#!/usr/bin/env bash
#
# Container deploy: pull the latest code, rebuild the images, restart the stack.
# The Docker equivalent of deploy.sh, which drives the systemd service instead.
#
# Runs ON THE SERVER. Called by .github/workflows/deploy.yml, and usable by hand:
#   ssh -i ~/.ssh/crud-key.pem ubuntu@<ip> 'bash /var/www/crud/deploy/aws/deploy-docker.sh'

set -euo pipefail

APP_DIR=/var/www/crud
BRANCH=master
ENV_FILE=.env.docker

cd "$APP_DIR"

if [[ ! -f $ENV_FILE ]]; then
  echo "!! $APP_DIR/$ENV_FILE is missing — the stack would start with the" >&2
  echo "   local development passwords. Create it first (see EC2-DOCKER.md)." >&2
  exit 1
fi

COMPOSE=(docker compose --env-file "$ENV_FILE")

echo "==> Fetching origin/$BRANCH"
git fetch origin "$BRANCH"

OLD_REV="$(git rev-parse HEAD)"
NEW_REV="$(git rev-parse "origin/$BRANCH")"

if [[ $OLD_REV == "$NEW_REV" ]]; then
  echo "Already at ${NEW_REV:0:7}."
else
  echo "==> ${OLD_REV:0:7} -> ${NEW_REV:0:7}"
  # The remote is the source of truth for a deploy target; local edits here are
  # discarded deliberately. .env.docker is untracked, so it survives.
  git reset --hard "origin/$BRANCH"
fi

echo "==> Building images"
"${COMPOSE[@]}" build

echo "==> Starting stack"
# --remove-orphans cleans up containers from services deleted in the compose file.
"${COMPOSE[@]}" up -d --remove-orphans

echo "==> Waiting for health check"
for i in {1..20}; do
  if curl -fsS -m 3 http://127.0.0.1:3000/health >/dev/null 2>&1; then
    echo "Healthy: $(curl -s http://127.0.0.1:3000/health)"
    echo "==> Deployed ${NEW_REV:0:7}"

    # Reclaim disk from superseded image layers. The root volume is small and
    # every rebuild leaves the previous image behind as an untagged layer.
    docker image prune -f >/dev/null 2>&1 || true
    exit 0
  fi
  sleep 3
done

echo "!! Health check failed after 60s. Container state and logs:" >&2
"${COMPOSE[@]}" ps >&2
"${COMPOSE[@]}" logs --tail=40 >&2
exit 1
