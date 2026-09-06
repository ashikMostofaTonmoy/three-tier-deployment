#!/usr/bin/env bash
# =============================================================================
#  Build the frontend on THIS machine and ship it to a running EC2 instance
#  over SSH. This is the "grown-up" version of the manual steps in the README:
#  build -> package -> copy -> swap the "current" symlink -> reload Nginx.
#
#  Usage:
#    scripts/deploy.sh                         # read host + key from infra/.lab-state
#    scripts/deploy.sh <public-ip> <key.pem>   # or pass them explicitly
#
#  Env:
#    BUILD_ID   label baked into the build (default: git short SHA + timestamp)
#    KEEP       how many old releases to keep on the server (default: 5)
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."

STATE="infra/.lab-state"
HOST="${1:-$( [ -f "$STATE" ] && sed -n 's/^PUBLIC_IP=//p' "$STATE" | tail -1 )}"
KEY="${2:-infra/three-tier-key.pem}"
KEEP="${KEEP:-5}"
BUILD_ID="${BUILD_ID:-$(git rev-parse --short HEAD 2>/dev/null || echo dev)-$(date -u +%Y%m%dT%H%M%SZ)}"

[ -n "$HOST" ] || { echo "no host: pass it as arg 1 or run infra/01-ec2.sh first"; exit 1; }
[ -f "$KEY" ]  || { echo "no key file: $KEY"; exit 1; }
SSH=(ssh -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null)

echo "==> building frontend (BUILD_ID=$BUILD_ID)"
( cd frontend && npm ci --silent && BUILD_ID="$BUILD_ID" npm run build )

echo "==> packaging"
TARBALL="$(mktemp -u).tgz"
tar -C frontend/dist -czf "$TARBALL" .

echo "==> uploading to $HOST"
scp -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  "$TARBALL" "ubuntu@${HOST}:/tmp/release.tgz"
rm -f "$TARBALL"

echo "==> activating new release on the server"
"${SSH[@]}" "ubuntu@${HOST}" KEEP="$KEEP" 'bash -s' <<'REMOTE'
set -e
RELEASE="/var/www/three-tier/releases/$(date -u +%Y%m%d%H%M%S)"
sudo mkdir -p "$RELEASE"
sudo tar -C "$RELEASE" -xzf /tmp/release.tgz
sudo ln -sfn "$RELEASE" /var/www/three-tier/current      # atomic swap
sudo nginx -t && sudo systemctl reload nginx
rm -f /tmp/release.tgz

# keep only the newest $KEEP releases
cd /var/www/three-tier/releases
ls -1dt */ | tail -n +$((KEEP + 1)) | xargs -r sudo rm -rf

echo "current -> $(readlink -f /var/www/three-tier/current)"
REMOTE

echo "==> verifying over HTTP"
code=$(curl -s -o /dev/null -w '%{http_code}' "http://${HOST}/")
api=$(curl -s -o /dev/null -w '%{http_code}' "http://${HOST}/api/v1/forecast?latitude=1.35&longitude=103.82&current=temperature_2m&timezone=auto")
live=$(curl -s "http://${HOST}/$(curl -s "http://${HOST}/" | grep -o 'assets/index-[^"]*\.js')" | grep -o "$BUILD_ID" | head -1)
echo "    GET /        -> $code"
echo "    GET /api/... -> $api"
echo "    live build   -> ${live:-<not found>}"
[ "$code" = "200" ] && [ "$api" = "200" ] && [ "$live" = "$BUILD_ID" ] \
  && echo "==> OK  http://${HOST}/" \
  || { echo "==> deploy verification FAILED"; exit 1; }
