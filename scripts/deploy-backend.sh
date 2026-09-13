#!/usr/bin/env bash
# =============================================================================
#  Tier 2. Ship backend/ to the VM and bring it up under PM2 in CLUSTER mode.
#
#  Zero-downtime: uses `pm2 startOrReload` — the FIRST run starts 2 worker
#  processes behind one port; every run after that RELOADS them one at a
#  time, so at least one worker is always answering requests. Never
#  `pm2 restart` (that stops everything, then starts — a real outage window).
#
#  Usage: scripts/deploy-backend.sh
#  Requires scripts/deploy-db.sh to have run at least once (needs DB_PASSWORD).
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."
source infra/_common.sh

HOST="$(state_get PUBLIC_IP)"; : "${HOST:?run infra/01-ec2.sh first}"
DB_PASSWORD="$(state_get DB_PASSWORD)"; : "${DB_PASSWORD:?run scripts/deploy-db.sh first}"
SSH=(ssh -i "$KEY_FILE" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "ubuntu@${HOST}")
SCP=(scp -i "$KEY_FILE" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null)

echo "==> installing Node 22 + PM2 on ${HOST} (skipped if already present)"
"${SSH[@]}" 'bash -s' <<'REMOTE'
set -e
if ! command -v node >/dev/null 2>&1; then
  curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash - >/dev/null
  sudo apt-get install -y -qq nodejs
fi
if ! command -v pm2 >/dev/null 2>&1; then
  sudo npm install -g pm2 >/dev/null
fi
node --version; pm2 --version
REMOTE

echo "==> packaging backend/"
TARBALL="$(mktemp -u).tgz"
tar --exclude node_modules -czf "$TARBALL" -C backend .

echo "==> uploading to ${HOST}"
"${SSH[@]}" 'mkdir -p /tmp/backend-upload'
"${SCP[@]}" "$TARBALL" "ubuntu@${HOST}:/tmp/backend.tgz"
rm -f "$TARBALL"

echo "==> installing deps + (re)starting under PM2"
"${SSH[@]}" DB_PASSWORD="$DB_PASSWORD" 'bash -s' <<'REMOTE'
set -e
sudo mkdir -p /opt/three-tier-backend
sudo tar -C /opt/three-tier-backend -xzf /tmp/backend.tgz
rm -f /tmp/backend.tgz
sudo chown -R ubuntu:ubuntu /opt/three-tier-backend
cd /opt/three-tier-backend

npm ci --omit=dev --silent

cat > .env <<EOF
PORT=3000
NODE_ENV=production
DATABASE_URL=postgresql://three_tier_user:${DB_PASSWORD}@localhost:5432/three_tier
PM2_INSTANCES=2
EOF

# startOrReload: first time = start (2 cluster workers); every time after =
# a rolling, zero-downtime reload of those same workers.
pm2 startOrReload ecosystem.config.cjs --update-env
pm2 save

# Make PM2 survive a reboot (idempotent — safe to run every time).
STARTUP_CMD="$(pm2 startup systemd -u ubuntu --hp /home/ubuntu | grep '^sudo ' || true)"
[ -n "$STARTUP_CMD" ] && eval "$STARTUP_CMD" >/dev/null 2>&1 || true

sleep 1
pm2 list
curl -s -o /dev/null -w "local /health -> %{http_code}\n" http://localhost:3000/health
REMOTE

echo "==> OK — backend is live on port 3000 (behind Nginx's /api/ proxy)"
