#!/usr/bin/env bash
# =============================================================================
#  Delete everything infra/01-ec2.sh and infra/02-cicd.sh created.
#  Safe to run more than once. Reads IDs from infra/.lab-state.
#  The GitHub OIDC provider is removed ONLY if this lab created it.
# =============================================================================
source "$(dirname "$0")/_common.sh"
banner
[ -f "$STATE_FILE" ] || { echo "no infra/.lab-state — nothing to do"; exit 0; }

ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"
INSTANCE_ID="$(state_get INSTANCE_ID)"
SG_ID="$(state_get SG_ID)"
ROLE_NAME="$(state_get ROLE_NAME)"
PROFILE_NAME="$(state_get PROFILE_NAME)"
KEY_NAME="$(state_get KEY_NAME)"
BUCKET="$(state_get BUCKET)"
CREATED_OIDC="$(state_get CREATED_OIDC)"
OIDC_ARN="arn:aws:iam::${ACCOUNT}:oidc-provider/token.actions.githubusercontent.com"

step() { echo "  - $*"; }

# ---- also catch the userdata-test instance from the README, if present ----
UDTEST="$(aws ec2 describe-instances \
  --filters Name=tag:Name,Values="${PREFIX}-web-udtest" \
    "Name=instance-state-name,Values=pending,running,stopping,stopped" \
  --query 'Reservations[].Instances[].InstanceId' --output text 2>/dev/null || true)"

echo "Terminating instances…"
for id in $INSTANCE_ID $UDTEST; do
  [ -n "$id" ] && [ "$id" != "None" ] || continue
  aws ec2 terminate-instances --instance-ids "$id" >/dev/null && step "instance $id"
done
for id in $INSTANCE_ID $UDTEST; do
  [ -n "$id" ] && [ "$id" != "None" ] || continue
  aws ec2 wait instance-terminated --instance-ids "$id" 2>/dev/null || true
done

echo "Deleting CI/CD resources…"
if [ -n "$BUCKET" ]; then
  aws s3 rm "s3://$BUCKET" --recursive >/dev/null 2>&1 || true
  aws s3api delete-bucket --bucket "$BUCKET" >/dev/null 2>&1 && step "s3://$BUCKET" || true
fi
if aws iam get-role --role-name "$CICD_ROLE_NAME" >/dev/null 2>&1; then
  for p in $(aws iam list-role-policies --role-name "$CICD_ROLE_NAME" --query 'PolicyNames[]' --output text); do
    aws iam delete-role-policy --role-name "$CICD_ROLE_NAME" --policy-name "$p"
  done
  aws iam delete-role --role-name "$CICD_ROLE_NAME" && step "role $CICD_ROLE_NAME"
fi
if [ "$CREATED_OIDC" = "true" ]; then
  aws iam delete-open-id-connect-provider --open-id-connect-provider-arn "$OIDC_ARN" \
    && step "OIDC provider (created by this lab)" || true
else
  step "OIDC provider left in place (pre-existing or unknown)"
fi

echo "Deleting instance resources…"
if [ -n "$PROFILE_NAME" ] && aws iam get-instance-profile --instance-profile-name "$PROFILE_NAME" >/dev/null 2>&1; then
  aws iam remove-role-from-instance-profile --instance-profile-name "$PROFILE_NAME" --role-name "$ROLE_NAME" 2>/dev/null || true
  aws iam delete-instance-profile --instance-profile-name "$PROFILE_NAME" && step "instance profile $PROFILE_NAME"
fi
if [ -n "$ROLE_NAME" ] && aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
  for p in $(aws iam list-role-policies --role-name "$ROLE_NAME" --query 'PolicyNames[]' --output text); do
    aws iam delete-role-policy --role-name "$ROLE_NAME" --policy-name "$p"
  done
  for a in $(aws iam list-attached-role-policies --role-name "$ROLE_NAME" --query 'AttachedPolicies[].PolicyArn' --output text); do
    aws iam detach-role-policy --role-name "$ROLE_NAME" --policy-arn "$a"
  done
  aws iam delete-role --role-name "$ROLE_NAME" && step "role $ROLE_NAME"
fi
if [ -n "$SG_ID" ] && [ "$SG_ID" != "None" ]; then
  aws ec2 delete-security-group --group-id "$SG_ID" 2>/dev/null && step "security group $SG_ID" \
    || echo "    (security group $SG_ID not deleted yet — retry in a minute)"
fi
if [ -n "$KEY_NAME" ]; then
  aws ec2 delete-key-pair --key-name "$KEY_NAME" >/dev/null && step "key pair $KEY_NAME"
  rm -f "$KEY_FILE" && step "local $KEY_FILE"
fi

rm -f "$STATE_FILE"
echo "Done. infra/.lab-state removed."
