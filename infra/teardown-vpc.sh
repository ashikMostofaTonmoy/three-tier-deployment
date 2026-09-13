#!/usr/bin/env bash
# =============================================================================
#  Delete everything Part 5/6 created, in dependency order:
#    ALB -> target group -> RDS -> NAT Gateway -> EIP -> instances ->
#    IAM role/profile -> security groups -> route tables -> subnets -> IGW -> VPC
#  Safe to re-run. Reads infra/.lab-state-vpc.
# =============================================================================
source "$(dirname "$0")/_common-vpc.sh"
banner
[ -f "$STATE_FILE" ] || { echo "no infra/.lab-state-vpc — nothing to do"; exit 0; }

FAILED=0
step() { echo "  - $*"; }

ALB_ARN="$(state_get ALB_ARN)"
TG_ARN="$(state_get TG_ARN)"
DB_INSTANCE_ID="$(state_get DB_INSTANCE_ID)"
NAT_ID="$(state_get NAT_ID)"
EIP_ALLOC="$(state_get EIP_ALLOC)"
FRONTEND_ID="$(state_get FRONTEND_INSTANCE_ID)"
BACKEND_ID="$(state_get BACKEND_INSTANCE_ID)"
ROLE_NAME="${PREFIX}-ssm-role"
PROFILE_NAME="${PREFIX}-ssm-profile"
ALB_SG="$(state_get ALB_SG)"
FRONTEND_SG="$(state_get FRONTEND_SG)"
BACKEND_SG="$(state_get BACKEND_SG)"
DB_SG="$(state_get DB_SG)"
PUB_RT="$(state_get PUB_RT)"
PRIV_RT="$(state_get PRIV_RT)"
IGW_ID="$(state_get IGW_ID)"
VPC_ID="$(state_get VPC_ID)"

echo "Load balancer…"
if [ -n "$ALB_ARN" ]; then
  aws elbv2 delete-load-balancer --load-balancer-arn "$ALB_ARN" 2>/dev/null && step "ALB" || true
  sleep 15  # ALB deletion is async; the target group can't be deleted until it's gone
fi
[ -n "$TG_ARN" ] && { aws elbv2 delete-target-group --target-group-arn "$TG_ARN" 2>/dev/null && step "target group" || { echo "    (target group not deletable yet — retry the script in a minute)"; FAILED=1; }; }

echo "RDS…"
if [ -n "$DB_INSTANCE_ID" ]; then
  aws rds delete-db-instance --db-instance-identifier "$DB_INSTANCE_ID" --skip-final-snapshot >/dev/null 2>&1 \
    && step "RDS instance $DB_INSTANCE_ID (deleting — takes a few minutes)" || true
  aws rds wait db-instance-deleted --db-instance-identifier "$DB_INSTANCE_ID" 2>/dev/null || true
fi
aws rds delete-db-subnet-group --db-subnet-group-name "${PREFIX}-db-subnet-group" 2>/dev/null \
  && step "DB subnet group" || true

echo "Instances…"
for id in "$FRONTEND_ID" "$BACKEND_ID"; do
  [ -n "$id" ] && aws ec2 terminate-instances --instance-ids "$id" >/dev/null 2>&1 && step "instance $id"
done
for id in "$FRONTEND_ID" "$BACKEND_ID"; do
  [ -n "$id" ] && aws ec2 wait instance-terminated --instance-ids "$id" 2>/dev/null || true
done

echo "NAT Gateway + Elastic IP…"
if [ -n "$NAT_ID" ]; then
  aws ec2 delete-nat-gateway --nat-gateway-id "$NAT_ID" >/dev/null 2>&1 && step "NAT gateway $NAT_ID (deleting)"
  wait_for "NAT Gateway to fully delete" \
    "aws ec2 describe-nat-gateways --nat-gateway-ids $NAT_ID --query 'NatGateways[0].State' --output text" \
    "deleted" || true
fi
[ -n "$EIP_ALLOC" ] && { aws ec2 release-address --allocation-id "$EIP_ALLOC" 2>/dev/null && step "Elastic IP $EIP_ALLOC" || true; }

echo "Deploy bucket…"
DEPLOY_BUCKET="$(state_get DEPLOY_BUCKET)"
if [ -n "$DEPLOY_BUCKET" ]; then
  aws s3 rm "s3://$DEPLOY_BUCKET" --recursive >/dev/null 2>&1 || true
  aws s3api delete-bucket --bucket "$DEPLOY_BUCKET" 2>/dev/null && step "s3://$DEPLOY_BUCKET" || true
fi

echo "IAM…"
if aws iam get-instance-profile --instance-profile-name "$PROFILE_NAME" >/dev/null 2>&1; then
  aws iam remove-role-from-instance-profile --instance-profile-name "$PROFILE_NAME" --role-name "$ROLE_NAME" 2>/dev/null || true
  aws iam delete-instance-profile --instance-profile-name "$PROFILE_NAME" && step "instance profile"
fi
if aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
  aws iam delete-role-policy --role-name "$ROLE_NAME" --policy-name read-deploy-bucket 2>/dev/null || true
  aws iam detach-role-policy --role-name "$ROLE_NAME" --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore 2>/dev/null || true
  aws iam delete-role --role-name "$ROLE_NAME" && step "role $ROLE_NAME"
fi

echo "Security groups…"
# The four SGs reference EACH OTHER (frontend-sg allows from backend-sg for
# monitoring, backend-sg allows from frontend-sg for the API, etc.) — AWS
# won't delete a group that's still named as a source in another group's
# rule, and with rules on both sides that's a genuine cycle. Revoke every
# rule on all four FIRST (breaking any cycle), then delete the now-empty
# groups — found live, the naive "just try to delete each" order deadlocks.
for sg in "$ALB_SG" "$FRONTEND_SG" "$BACKEND_SG" "$DB_SG"; do
  [ -n "$sg" ] || continue
  RULE_IDS="$(aws ec2 describe-security-group-rules --filters "Name=group-id,Values=$sg" \
    --query 'SecurityGroupRules[?!IsEgress].SecurityGroupRuleId' --output text 2>/dev/null || true)"
  [ -n "$RULE_IDS" ] && aws ec2 revoke-security-group-ingress --group-id "$sg" --security-group-rule-ids $RULE_IDS 2>/dev/null || true
done
for sg in "$ALB_SG" "$FRONTEND_SG" "$BACKEND_SG" "$DB_SG"; do
  [ -n "$sg" ] && { aws ec2 delete-security-group --group-id "$sg" 2>/dev/null && step "SG $sg" || { echo "    (SG $sg not deletable yet — retry in a minute)"; FAILED=1; }; }
done

echo "Route tables, subnets, IGW, VPC…"
for rt in "$PUB_RT" "$PRIV_RT"; do
  [ -n "$rt" ] || continue
  for assoc in $(aws ec2 describe-route-tables --route-table-ids "$rt" --query 'RouteTables[0].Associations[?!Main].RouteTableAssociationId' --output text 2>/dev/null); do
    aws ec2 disassociate-route-table --association-id "$assoc" 2>/dev/null || true
  done
  aws ec2 delete-route-table --route-table-id "$rt" 2>/dev/null && step "route table $rt" || true
done
for s in PUBLIC_A PUBLIC_B PRIVATE_APP_A PRIVATE_APP_B PRIVATE_DB_A PRIVATE_DB_B; do
  id="$(state_get "$s")"
  [ -n "$id" ] && { aws ec2 delete-subnet --subnet-id "$id" 2>/dev/null && step "subnet $id ($s)" || true; }
done
if [ -n "$IGW_ID" ] && [ -n "$VPC_ID" ]; then
  aws ec2 detach-internet-gateway --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID" 2>/dev/null || true
  aws ec2 delete-internet-gateway --internet-gateway-id "$IGW_ID" 2>/dev/null && step "internet gateway $IGW_ID"
fi
[ -n "$VPC_ID" ] && { aws ec2 delete-vpc --vpc-id "$VPC_ID" 2>/dev/null && step "VPC $VPC_ID" || { echo "    (VPC not deletable yet — something above needs a retry)"; FAILED=1; }; }

[ -n "${KEY_NAME:-}" ] && { aws ec2 delete-key-pair --key-name "$KEY_NAME" >/dev/null 2>&1 && step "key pair $KEY_NAME"; rm -f "$KEY_FILE"; }

if [ "$FAILED" = "1" ]; then
  echo "Some resources weren't deletable yet (see the notes above, usually a few"
  echo "seconds of AWS-side lag) — infra/.lab-state-vpc kept so you can just"
  echo "re-run this script in a minute."
else
  rm -f "$STATE_FILE"
  echo "Done. infra/.lab-state-vpc removed."
fi
