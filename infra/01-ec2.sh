#!/usr/bin/env bash
# =============================================================================
#  Create everything needed to run one web server:
#    - an SSH key pair            (three-tier-key.pem, saved next to this script)
#    - a security group           (three-tier-sg: SSH from your IP, HTTP from all)
#    - an IAM role + profile       (lets the instance be managed by AWS SSM)
#    - one t3.micro EC2 instance   (Ubuntu 24.04)
#
#  Usage:
#    ./01-ec2.sh                       # plain instance, deploy to it later
#    ./01-ec2.sh --user-data FILE      # run FILE on first boot (self-deploy)
#
#  Writes all IDs to infra/.lab-state. Re-running is safe (it reuses what exists).
#  Tear it all down with: ./teardown.sh
# =============================================================================
source "$(dirname "$0")/_common.sh"

USER_DATA_FILE=""
[ "${1:-}" = "--user-data" ] && USER_DATA_FILE="${2:?path to user-data file}"

banner

# ---- 1. Find the newest Ubuntu 24.04 image published by Canonical -----------
# Owner 099720109477 is Canonical's official AWS account. We take the most
# recently created "noble 24.04" server image for amd64.
AMI_ID="$(aws ec2 describe-images --owners 099720109477 \
  --filters \
    'Name=name,Values=ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*' \
    'Name=state,Values=available' \
  --query 'sort_by(Images,&CreationDate)[-1].ImageId' --output text)"
echo "Ubuntu 24.04 AMI : $AMI_ID"

# ---- 2. Default VPC + one public subnet -------------------------------------
VPC_ID="$(aws ec2 describe-vpcs --filters Name=isDefault,Values=true \
  --query 'Vpcs[0].VpcId' --output text)"
SUBNET_ID="$(aws ec2 describe-subnets \
  --filters Name=vpc-id,Values="$VPC_ID" Name=default-for-az,Values=true \
  --query 'Subnets[0].SubnetId' --output text)"
echo "VPC / subnet     : $VPC_ID / $SUBNET_ID"

# ---- 3. SSH key pair -------------------------------------------------------
if aws ec2 describe-key-pairs --key-names "$KEY_NAME" >/dev/null 2>&1; then
  echo "Key pair         : $KEY_NAME (already exists)"
else
  aws ec2 create-key-pair --key-name "$KEY_NAME" \
    --query KeyMaterial --output text > "$KEY_FILE"
  chmod 600 "$KEY_FILE"
  echo "Key pair         : $KEY_NAME  ->  $KEY_FILE"
fi

# ---- 4. Security group ---------------------------------------------------
SG_ID="$(aws ec2 describe-security-groups \
  --filters Name=group-name,Values="$SG_NAME" Name=vpc-id,Values="$VPC_ID" \
  --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || true)"
if [ "$SG_ID" = "None" ] || [ -z "$SG_ID" ]; then
  SG_ID="$(aws ec2 create-security-group --group-name "$SG_NAME" \
    --description "Weather Board web server" --vpc-id "$VPC_ID" \
    --query GroupId --output text)"
  MY_IP="$(curl -s https://checkip.amazonaws.com | tr -d '[:space:]')"
  aws ec2 authorize-security-group-ingress --group-id "$SG_ID" \
    --ip-permissions \
      IpProtocol=tcp,FromPort=22,ToPort=22,IpRanges="[{CidrIp=${MY_IP}/32,Description=my-ip-ssh}]" \
      IpProtocol=tcp,FromPort=80,ToPort=80,IpRanges="[{CidrIp=0.0.0.0/0,Description=http-public}]" \
    >/dev/null
  echo "Security group   : $SG_NAME ($SG_ID)  — SSH from ${MY_IP}/32, HTTP from anywhere"
else
  echo "Security group   : $SG_NAME ($SG_ID) (already exists)"
fi

# ---- 5. IAM role + instance profile for SSM ----------------------------
if ! aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
  aws iam create-role --role-name "$ROLE_NAME" \
    --assume-role-policy-document '{
      "Version":"2012-10-17",
      "Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]
    }' >/dev/null
  aws iam attach-role-policy --role-name "$ROLE_NAME" \
    --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore >/dev/null
  echo "IAM role         : $ROLE_NAME (created)"
else
  echo "IAM role         : $ROLE_NAME (already exists)"
fi
if ! aws iam get-instance-profile --instance-profile-name "$PROFILE_NAME" >/dev/null 2>&1; then
  aws iam create-instance-profile --instance-profile-name "$PROFILE_NAME" >/dev/null
  aws iam add-role-to-instance-profile --instance-profile-name "$PROFILE_NAME" \
    --role-name "$ROLE_NAME" >/dev/null
  echo "Instance profile : $PROFILE_NAME (created) — waiting 10s for it to propagate"
  sleep 10
else
  echo "Instance profile : $PROFILE_NAME (already exists)"
fi

# ---- 6. Launch the instance (only if we don't already have a running one) --
EXISTING="$(aws ec2 describe-instances \
  --filters Name=tag:Name,Values="$INSTANCE_TAG" "Name=instance-state-name,Values=pending,running" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text 2>/dev/null || true)"
if [ "$EXISTING" != "None" ] && [ -n "$EXISTING" ]; then
  INSTANCE_ID="$EXISTING"
  echo "Instance         : $INSTANCE_ID (already running)"
else
  RUN_ARGS=(
    --image-id "$AMI_ID" --instance-type t3.micro
    --key-name "$KEY_NAME" --security-group-ids "$SG_ID" --subnet-id "$SUBNET_ID"
    --iam-instance-profile Name="$PROFILE_NAME"
    --associate-public-ip-address
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${INSTANCE_TAG}}]"
    --metadata-options "HttpTokens=required,HttpEndpoint=enabled"
  )
  [ -n "$USER_DATA_FILE" ] && RUN_ARGS+=(--user-data "file://${USER_DATA_FILE}")
  INSTANCE_ID="$(aws ec2 run-instances "${RUN_ARGS[@]}" \
    --query 'Instances[0].InstanceId' --output text)"
  echo "Instance         : $INSTANCE_ID (launching)"
fi

echo "Waiting for the instance to be running and healthy…"
aws ec2 wait instance-status-ok --instance-ids "$INSTANCE_ID"

PUBLIC_IP="$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)"

state_put VPC_ID "$VPC_ID"
state_put SUBNET_ID "$SUBNET_ID"
state_put SG_ID "$SG_ID"
state_put ROLE_NAME "$ROLE_NAME"
state_put PROFILE_NAME "$PROFILE_NAME"
state_put KEY_NAME "$KEY_NAME"
state_put INSTANCE_ID "$INSTANCE_ID"
state_put PUBLIC_IP "$PUBLIC_IP"

echo
echo "  DONE"
echo "  INSTANCE_ID = $INSTANCE_ID"
echo "  PUBLIC_IP   = $PUBLIC_IP"
echo "  open http://$PUBLIC_IP/  (nothing there yet until you deploy)"
