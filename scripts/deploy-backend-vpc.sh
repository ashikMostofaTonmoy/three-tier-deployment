#!/usr/bin/env bash
# =============================================================================
#  Ship backend/ to the backend instance over SSM (no SSH — it has no public
#  IP at all, this is the ONLY way in) and bring it up under PM2 in cluster
#  mode, same zero-downtime pattern as Part 2 (`pm2 startOrReload`).
#  DATABASE_URL now points at the RDS endpoint, not localhost.
#
#  Usage: scripts/deploy-backend-vpc.sh
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."
source infra/_common-vpc.sh

BACKEND_ID="$(state_get BACKEND_INSTANCE_ID)"; : "${BACKEND_ID:?run infra/44-ec2-instances.sh first}"
DB_ENDPOINT="$(state_get DB_ENDPOINT)"; : "${DB_ENDPOINT:?run infra/43-rds.sh first}"
DB_NAME="$(state_get DB_NAME)"; DB_USER="$(state_get DB_USER)"; DB_PASSWORD="$(state_get DB_PASSWORD)"
DEPLOY_BUCKET="$(state_get DEPLOY_BUCKET)"; : "${DEPLOY_BUCKET:?run infra/44-ec2-instances.sh first}"

echo "==> packaging backend/"
TARBALL="$(mktemp -u).tgz"
tar --exclude node_modules -czf "$TARBALL" -C backend .
aws s3 cp "$TARBALL" "s3://${DEPLOY_BUCKET}/backend.tgz"
rm -f "$TARBALL"

TMP="$(mktemp)"
cat > "$TMP" <<EOF
set -e
if ! command -v node >/dev/null 2>&1; then
  curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash - >/dev/null 2>&1
  sudo apt-get install -y -qq nodejs
fi
command -v pm2 >/dev/null 2>&1 || sudo npm install -g pm2 >/dev/null 2>&1
if ! command -v aws >/dev/null 2>&1; then
  curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
  sudo apt-get install -y -qq unzip
  unzip -q -o /tmp/awscliv2.zip -d /tmp
  sudo /tmp/aws/install
  rm -rf /tmp/aws /tmp/awscliv2.zip
fi

aws s3 cp s3://${DEPLOY_BUCKET}/backend.tgz /tmp/backend.tgz
sudo mkdir -p /opt/three-tier-backend
sudo tar -C /opt/three-tier-backend -xzf /tmp/backend.tgz
sudo chown -R ubuntu:ubuntu /opt/three-tier-backend
rm -f /tmp/backend.tgz
cd /opt/three-tier-backend
sudo -u ubuntu -H npm ci --omit=dev --silent

cat <<ENVEOF | sudo -u ubuntu tee .env >/dev/null
PORT=3000
NODE_ENV=production
DATABASE_URL=postgresql://${DB_USER}:${DB_PASSWORD}@${DB_ENDPOINT}:5432/${DB_NAME}
PGSSL=true
PM2_INSTANCES=2
ENVEOF

sudo -u ubuntu -H pm2 startOrReload ecosystem.config.cjs --update-env
sudo -u ubuntu -H pm2 save
sleep 1
sudo -u ubuntu -H pm2 list
curl -s -o /dev/null -w "local backend /health -> %{http_code}\n" http://localhost:3000/health
EOF

echo "==> installing + starting the backend on ${BACKEND_ID} (via SSM)"
ssm_run "$BACKEND_ID" "$TMP"
rm -f "$TMP"

echo "==> OK — backend live on port 3000, DATABASE_URL -> ${DB_ENDPOINT}"
