#!/usr/bin/env bash
#
# Pulls the latest code and restarts the app. Runs ON THE SERVER.
#
# Called automatically by .github/workflows/deploy.yml on every push to master,
# and usable by hand:
#   ssh -i ~/.ssh/crud-key.pem ubuntu@<ip> 'bash /var/www/crud/deploy/aws/deploy.sh'

set -euo pipefail

APP_DIR=/var/www/crud
BRANCH=master

cd "$APP_DIR"

echo "==> Fetching origin/$BRANCH"
git fetch origin "$BRANCH"

OLD_REV="$(git rev-parse HEAD)"
NEW_REV="$(git rev-parse "origin/$BRANCH")"

if [[ $OLD_REV == "$NEW_REV" ]]; then
  echo "Already at ${NEW_REV:0:7}, nothing to pull."
else
  echo "==> ${OLD_REV:0:7} -> ${NEW_REV:0:7}"
  # Hard reset rather than merge: this is a deploy target, so the remote is
  # always the source of truth. Any local edits here are discarded on purpose.
  git reset --hard "origin/$BRANCH"
fi

# Only reinstall when the dependency manifest actually changed — npm install
# is the slowest step and usually unnecessary.
if [[ $OLD_REV != "$NEW_REV" ]] && \
   ! git diff --quiet "$OLD_REV" "$NEW_REV" -- package.json package-lock.json; then
  echo "==> Dependencies changed, reinstalling"
  npm install --omit=dev --no-audit --no-fund
else
  echo "==> Dependencies unchanged, skipping npm install"
fi

echo "==> Restarting service"
sudo systemctl restart crud

echo "==> Waiting for health check"
for i in {1..10}; do
  if curl -fsS -m 3 http://127.0.0.1:3000/health >/dev/null 2>&1; then
    echo "Healthy: $(curl -s http://127.0.0.1:3000/health)"
    echo "==> Deployed ${NEW_REV:0:7}"
    exit 0
  fi
  sleep 2
done

echo "!! Health check failed after 20s. Recent logs:" >&2
sudo journalctl -u crud -n 30 --no-pager >&2
exit 1
