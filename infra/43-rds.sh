#!/usr/bin/env bash
# =============================================================================
#  A managed PostgreSQL database via Amazon RDS — in the private-db subnets,
#  never publicly accessible, reachable only from the backend's security
#  group on 5432. Compare with Part 2's self-managed Postgres: AWS now
#  handles patching, backups, and failover-readiness; you hand over shell
#  access to the database host in exchange (there is no "ssh into your RDS
#  instance" — everything is done through the Postgres wire protocol itself
#  or the AWS API).
#
#  Usage: ./43-rds.sh
#  RDS provisioning genuinely takes 5-10 minutes — this script waits for it.
# =============================================================================
source "$(dirname "$0")/_common-vpc.sh"
banner

PRIVATE_DB_A="$(state_get PRIVATE_DB_A)"; : "${PRIVATE_DB_A:?run ./40-vpc.sh first}"
PRIVATE_DB_B="$(state_get PRIVATE_DB_B)"
DB_SG="$(state_get DB_SG)"; : "${DB_SG:?run ./42-security-groups.sh first}"

DB_INSTANCE_ID="${PREFIX}-db"
DB_SUBNET_GROUP="${PREFIX}-db-subnet-group"
DB_NAME="three_tier"
DB_USER="three_tier_user"

# ---- 1. DB subnet group (must span >=2 AZs, even for a single-AZ instance) -
if ! aws rds describe-db-subnet-groups --db-subnet-group-name "$DB_SUBNET_GROUP" >/dev/null 2>&1; then
  aws rds create-db-subnet-group --db-subnet-group-name "$DB_SUBNET_GROUP" \
    --db-subnet-group-description "Three-tier lab - private DB subnets" \
    --subnet-ids "$PRIVATE_DB_A" "$PRIVATE_DB_B" \
    --tags "Key=Name,Value=${PREFIX}-db-subnet-group" >/dev/null
  echo "DB subnet group  : $DB_SUBNET_GROUP (created, spans 2 AZs)"
else
  echo "DB subnet group  : $DB_SUBNET_GROUP (already exists)"
fi

# ---- 2. The RDS instance itself --------------------------------------
DB_PASSWORD="$(state_get DB_PASSWORD)"
if [ -z "$DB_PASSWORD" ]; then
  DB_PASSWORD="$(openssl rand -hex 12)"
  state_put DB_PASSWORD "$DB_PASSWORD"
fi

STATUS="$(aws rds describe-db-instances --db-instance-identifier "$DB_INSTANCE_ID" \
  --query 'DBInstances[0].DBInstanceStatus' --output text 2>/dev/null || true)"
if [ -z "$STATUS" ] || [ "$STATUS" = "None" ]; then
  aws rds create-db-instance \
    --db-instance-identifier "$DB_INSTANCE_ID" \
    --db-instance-class db.t3.micro \
    --engine postgres \
    --master-username "$DB_USER" \
    --master-user-password "$DB_PASSWORD" \
    --db-name "$DB_NAME" \
    --allocated-storage 20 --storage-type gp3 \
    --db-subnet-group-name "$DB_SUBNET_GROUP" \
    --vpc-security-group-ids "$DB_SG" \
    --no-publicly-accessible \
    --no-multi-az \
    --backup-retention-period 0 \
    --no-deletion-protection \
    --tags "Key=Name,Value=${PREFIX}-db" \
    >/dev/null
  echo "RDS instance     : $DB_INSTANCE_ID (creating — this takes 5-10 minutes)"
else
  echo "RDS instance     : $DB_INSTANCE_ID (status: $STATUS)"
fi

wait_for "RDS instance to become available" \
  "aws rds describe-db-instances --db-instance-identifier $DB_INSTANCE_ID --query 'DBInstances[0].DBInstanceStatus' --output text" \
  "available"

ENDPOINT="$(aws rds describe-db-instances --db-instance-identifier "$DB_INSTANCE_ID" \
  --query 'DBInstances[0].Endpoint.Address' --output text)"
PUBLIC_FLAG="$(aws rds describe-db-instances --db-instance-identifier "$DB_INSTANCE_ID" \
  --query 'DBInstances[0].PubliclyAccessible' --output text)"

state_put DB_INSTANCE_ID "$DB_INSTANCE_ID"
state_put DB_ENDPOINT "$ENDPOINT"
state_put DB_NAME "$DB_NAME"
state_put DB_USER "$DB_USER"

echo
echo "  DONE."
echo "  Endpoint          : $ENDPOINT:5432"
echo "  Publicly reachable: $PUBLIC_FLAG   (must be False)"
echo "  Only reachable from security group $DB_SG (i.e. the backend instance)."
