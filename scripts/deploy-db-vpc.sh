#!/usr/bin/env bash
# =============================================================================
#  Apply the schema to the RDS instance. Run FROM the backend instance (via
#  SSM — never SSH) because RDS itself has no shell to run anything on; the
#  backend is the only thing in the VPC with both network access to RDS and
#  a place for `psql` to run.
#
#  Usage: scripts/deploy-db-vpc.sh
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."
source infra/_common-vpc.sh

BACKEND_ID="$(state_get BACKEND_INSTANCE_ID)"; : "${BACKEND_ID:?run infra/44-ec2-instances.sh first}"
DB_ENDPOINT="$(state_get DB_ENDPOINT)"; : "${DB_ENDPOINT:?run infra/43-rds.sh first}"
DB_NAME="$(state_get DB_NAME)"; DB_USER="$(state_get DB_USER)"; DB_PASSWORD="$(state_get DB_PASSWORD)"
DEPLOY_BUCKET="$(state_get DEPLOY_BUCKET)"; : "${DEPLOY_BUCKET:?run infra/44-ec2-instances.sh first}"

echo "==> uploading the migration to S3"
aws s3 cp database/migrations/001_create_search_history.sql "s3://${DEPLOY_BUCKET}/migration.sql"

TMP="$(mktemp)"
cat > "$TMP" <<EOF
set -e
if ! command -v psql >/dev/null 2>&1; then
  sudo apt-get update -y -qq
  sudo apt-get install -y -qq postgresql-client
fi
if ! command -v aws >/dev/null 2>&1; then
  curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
  sudo apt-get install -y -qq unzip
  unzip -q -o /tmp/awscliv2.zip -d /tmp
  sudo /tmp/aws/install
  rm -rf /tmp/aws /tmp/awscliv2.zip
fi
aws s3 cp s3://${DEPLOY_BUCKET}/migration.sql /tmp/migration.sql
PGPASSWORD='${DB_PASSWORD}' psql -h ${DB_ENDPOINT} -U ${DB_USER} -d ${DB_NAME} -v ON_ERROR_STOP=1 -f /tmp/migration.sql
PGPASSWORD='${DB_PASSWORD}' psql -h ${DB_ENDPOINT} -U ${DB_USER} -d ${DB_NAME} -c '\dt'
rm -f /tmp/migration.sql
EOF

echo "==> applying schema to ${DB_ENDPOINT} (via the backend instance, over SSM)"
ssm_run "$BACKEND_ID" "$TMP"
rm -f "$TMP"

echo "==> OK — schema applied to RDS"
