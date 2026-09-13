#!/usr/bin/env bash
# =============================================================================
#  Ship the frontend to the frontend instance over SSM (never SSH — even in
#  Class 5 where the frontend has a public IP, for consistency with the rest
#  of Part 5/6). Same atomic release+symlink pattern as Part 2. The Nginx
#  config points /api/ at the BACKEND's private IP — nginx/three-tier-vpc.conf
#  is a template; this script fills in the real address before installing it.
#
#  Usage: scripts/deploy-frontend-vpc.sh
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."
source infra/_common-vpc.sh

FRONTEND_ID="$(state_get FRONTEND_INSTANCE_ID)"; : "${FRONTEND_ID:?run infra/44-ec2-instances.sh first}"
BACKEND_PRIVATE_IP="$(state_get BACKEND_PRIVATE_IP)"; : "${BACKEND_PRIVATE_IP:?run infra/44-ec2-instances.sh first}"
DEPLOY_BUCKET="$(state_get DEPLOY_BUCKET)"; : "${DEPLOY_BUCKET:?run infra/44-ec2-instances.sh first}"

echo "==> building frontend (BUILD_ID=${BUILD_ID:=vpc-$(date -u +%Y%m%dT%H%M%SZ)})"
( cd frontend && npm ci --silent && BUILD_ID="$BUILD_ID" npm run build )
tar -C frontend/dist -czf /tmp/frontend-vpc.tgz .
aws s3 cp /tmp/frontend-vpc.tgz "s3://${DEPLOY_BUCKET}/frontend.tgz"
rm -f /tmp/frontend-vpc.tgz

echo "==> templating nginx config with backend private IP ${BACKEND_PRIVATE_IP}"
sed "s/BACKEND_PRIVATE_IP/${BACKEND_PRIVATE_IP}/" nginx/three-tier-vpc.conf > /tmp/nginx-vpc.conf
aws s3 cp /tmp/nginx-vpc.conf "s3://${DEPLOY_BUCKET}/nginx-three-tier.conf"
rm -f /tmp/nginx-vpc.conf

TMP="$(mktemp)"
cat > "$TMP" <<EOF
set -e
if ! command -v nginx >/dev/null 2>&1; then
  sudo apt-get update -y -qq
  sudo apt-get install -y -qq nginx
fi
if ! command -v aws >/dev/null 2>&1; then
  curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
  sudo apt-get install -y -qq unzip
  unzip -q -o /tmp/awscliv2.zip -d /tmp
  sudo /tmp/aws/install
  rm -rf /tmp/aws /tmp/awscliv2.zip
fi

aws s3 cp s3://${DEPLOY_BUCKET}/frontend.tgz /tmp/frontend.tgz
aws s3 cp s3://${DEPLOY_BUCKET}/nginx-three-tier.conf /tmp/nginx-three-tier.conf

RELEASE="/var/www/three-tier/releases/\$(date -u +%Y%m%d%H%M%S)"
sudo mkdir -p "\$RELEASE"
sudo tar -C "\$RELEASE" -xzf /tmp/frontend.tgz
sudo ln -sfn "\$RELEASE" /var/www/three-tier/current

sudo cp /tmp/nginx-three-tier.conf /etc/nginx/sites-available/three-tier
sudo ln -sfn /etc/nginx/sites-available/three-tier /etc/nginx/sites-enabled/three-tier
sudo rm -f /etc/nginx/sites-enabled/default
sudo nginx -t
sudo systemctl reload nginx

cd /var/www/three-tier/releases && ls -1dt */ | tail -n +6 | xargs -r sudo rm -rf
rm -f /tmp/frontend.tgz /tmp/nginx-three-tier.conf

echo "--- local verification ---"
curl -s -o /dev/null -w "GET /        -> %{http_code}\n" http://localhost/
curl -s -o /dev/null -w "GET /healthz -> %{http_code}\n" http://localhost/healthz
curl -s -o /dev/null -w "GET /api/v1/history -> %{http_code}\n" http://localhost/api/v1/history
EOF

echo "==> installing + deploying the frontend on ${FRONTEND_ID} (via SSM)"
ssm_run "$FRONTEND_ID" "$TMP"
rm -f "$TMP"

FRONTEND_PUBLIC_IP="$(state_get FRONTEND_PUBLIC_IP)"
if [ -n "$FRONTEND_PUBLIC_IP" ] && [ "$FRONTEND_PUBLIC_IP" != "None" ]; then
  echo "==> verifying from the internet: http://${FRONTEND_PUBLIC_IP}/"
  curl -s -o /dev/null -w "    GET / -> %{http_code}\n" "http://${FRONTEND_PUBLIC_IP}/"
else
  echo "==> frontend has no public IP (private subnet) — reach it via the ALB (Class 6, §55) or SSM port-forwarding"
fi

echo "==> OK"
