#!/usr/bin/env bash
# =============================================================================
#  Tier 3. Install Postgres on the VM (once) and apply every migration in
#  database/migrations/ in order. Safe to re-run: installs are skipped if
#  already done, and the migration itself uses CREATE TABLE IF NOT EXISTS.
#
#  Usage: scripts/deploy-db.sh
#  Reads PUBLIC_IP / KEY_NAME from infra/.lab-state (infra/01-ec2.sh).
#  Picks (and remembers) a DB password in infra/.lab-state — DB_PASSWORD.
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."
source infra/_common.sh

HOST="$(state_get PUBLIC_IP)"; : "${HOST:?run infra/01-ec2.sh first}"
SSH=(ssh -i "$KEY_FILE" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "ubuntu@${HOST}")
SCP=(scp -i "$KEY_FILE" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null)

DB_PASSWORD="$(state_get DB_PASSWORD)"
if [ -z "$DB_PASSWORD" ]; then
  DB_PASSWORD="$(openssl rand -hex 12)"
  state_put DB_PASSWORD "$DB_PASSWORD"
  echo "==> generated a new DB password (saved to infra/.lab-state, never committed)"
fi

echo "==> uploading the migration"
"${SCP[@]}" database/migrations/001_create_search_history.sql "ubuntu@${HOST}:/tmp/001_create_search_history.sql"

echo "==> installing Postgres + applying the schema on ${HOST}"
"${SSH[@]}" DB_PASSWORD="$DB_PASSWORD" 'bash -s' <<'REMOTE'
set -e
if ! command -v psql >/dev/null 2>&1; then
  echo "-- installing postgresql --"
  sudo apt-get update -y -qq
  sudo apt-get install -y -qq postgresql
fi
sudo systemctl enable --now postgresql

echo "-- creating role/database (idempotent) --"
sudo -u postgres psql -tc "SELECT 1 FROM pg_roles WHERE rolname='three_tier_user'" | grep -q 1 \
  && sudo -u postgres psql -c "ALTER ROLE three_tier_user WITH PASSWORD '${DB_PASSWORD}';" \
  || sudo -u postgres psql -c "CREATE ROLE three_tier_user WITH LOGIN PASSWORD '${DB_PASSWORD}';"
sudo -u postgres psql -tc "SELECT 1 FROM pg_database WHERE datname='three_tier'" | grep -q 1 \
  || sudo -u postgres psql -c "CREATE DATABASE three_tier OWNER three_tier_user;"

echo "-- applying migration (fails loudly on error, no silent swallow) --"
sudo -u postgres psql -v ON_ERROR_STOP=1 -d three_tier -f /tmp/001_create_search_history.sql
sudo -u postgres psql -d three_tier -c \
  "GRANT SELECT, INSERT, UPDATE, DELETE ON search_history TO three_tier_user;
   GRANT USAGE, SELECT ON SEQUENCE search_history_id_seq TO three_tier_user;"
rm -f /tmp/001_create_search_history.sql

echo "-- verifying --"
sudo -u postgres psql -d three_tier -c '\dt'
REMOTE

echo "==> OK — Postgres ready, DB_PASSWORD stored in infra/.lab-state"
