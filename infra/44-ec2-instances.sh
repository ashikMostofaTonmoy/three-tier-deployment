#!/usr/bin/env bash
# =============================================================================
#  Launch the frontend + backend EC2 instances into the new VPC.
#
#  The backend ALWAYS goes in a private subnet (private-app-a) — that never
#  changes between Class 5 and Class 6. The frontend's subnet is a flag:
#
#    ./44-ec2-instances.sh                    # Class 5: frontend in public-a (has a public IP)
#    ./44-ec2-instances.sh --frontend-subnet private   # Class 6: frontend in private-app-a (no public IP at all)
#
#  Re-running with a different --frontend-subnet TERMINATES and relaunches
#  only the frontend instance (the backend, if already running, is untouched).
#  Both instances get the same SSM instance profile as Parts 1-4 — it's the
#  ONLY way to reach the backend (and, in Class 6, the frontend too).
# =============================================================================
source "$(dirname "$0")/_common-vpc.sh"

FRONTEND_SUBNET_KIND="public"
[ "${1:-}" = "--frontend-subnet" ] && FRONTEND_SUBNET_KIND="${2:?public or private}"

banner
echo "Frontend subnet  : $FRONTEND_SUBNET_KIND"

VPC_ID="$(state_get VPC_ID)"; : "${VPC_ID:?run ./40-vpc.sh first}"
PUBLIC_A="$(state_get PUBLIC_A)"
PRIVATE_APP_A="$(state_get PRIVATE_APP_A)"
FRONTEND_SG="$(state_get FRONTEND_SG)"; : "${FRONTEND_SG:?run ./42-security-groups.sh first}"
BACKEND_SG="$(state_get BACKEND_SG)"

if [ "$FRONTEND_SUBNET_KIND" = "private" ]; then
  FRONTEND_SUBNET="$PRIVATE_APP_A"
  FRONTEND_ASSOC_PUBLIC_IP="--no-associate-public-ip-address"
else
  FRONTEND_SUBNET="$PUBLIC_A"
  FRONTEND_ASSOC_PUBLIC_IP="--associate-public-ip-address"
fi

# ---- Shared prerequisites: AMI, key pair, IAM role for SSM -----------------
AMI_ID="$(aws ec2 describe-images --owners 099720109477 \
  --filters 'Name=name,Values=ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*' 'Name=state,Values=available' \
  --query 'sort_by(Images,&CreationDate)[-1].ImageId' --output text)"
echo "Ubuntu 24.04 AMI : $AMI_ID"

if ! aws ec2 describe-key-pairs --key-names "$KEY_NAME" >/dev/null 2>&1; then
  aws ec2 create-key-pair --key-name "$KEY_NAME" --query KeyMaterial --output text > "$KEY_FILE"
  chmod 600 "$KEY_FILE"
  echo "Key pair         : $KEY_NAME -> $KEY_FILE"
else
  echo "Key pair         : $KEY_NAME (already exists)"
fi

ROLE_NAME="${PREFIX}-ssm-role"
PROFILE_NAME="${PREFIX}-ssm-profile"
if ! aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
  aws iam create-role --role-name "$ROLE_NAME" --assume-role-policy-document '{
    "Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]
  }' >/dev/null
  aws iam attach-role-policy --role-name "$ROLE_NAME" --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore >/dev/null
  echo "IAM role         : $ROLE_NAME (created)"
else
  echo "IAM role         : $ROLE_NAME (already exists)"
fi
if ! aws iam get-instance-profile --instance-profile-name "$PROFILE_NAME" >/dev/null 2>&1; then
  aws iam create-instance-profile --instance-profile-name "$PROFILE_NAME" >/dev/null
  aws iam add-role-to-instance-profile --instance-profile-name "$PROFILE_NAME" --role-name "$ROLE_NAME" >/dev/null
  echo "Instance profile : $PROFILE_NAME (created) — waiting 10s to propagate"
  sleep 10
else
  echo "Instance profile : $PROFILE_NAME (already exists)"
fi

# Every deploy script talks to these instances ONLY via SSM (no SSH, no scp —
# the "pure SSM" decision, and the only option at all once the frontend is
# private too). Files have to get onto the box some other way, so both
# instances can read a small S3 bucket used purely as a staging area.
ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"
DEPLOY_BUCKET="${PREFIX}-deploy-${ACCOUNT}"
if ! aws s3api head-bucket --bucket "$DEPLOY_BUCKET" 2>/dev/null; then
  aws s3api create-bucket --bucket "$DEPLOY_BUCKET" \
    --create-bucket-configuration LocationConstraint="$AWS_REGION" >/dev/null
  aws s3api put-public-access-block --bucket "$DEPLOY_BUCKET" \
    --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
  echo "Deploy bucket    : $DEPLOY_BUCKET (created, private)"
else
  echo "Deploy bucket    : $DEPLOY_BUCKET (already exists)"
fi
aws iam put-role-policy --role-name "$ROLE_NAME" --policy-name read-deploy-bucket --policy-document "$(cat <<JSON
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":"s3:GetObject","Resource":"arn:aws:s3:::${DEPLOY_BUCKET}/*"}]}
JSON
)" >/dev/null
state_put DEPLOY_BUCKET "$DEPLOY_BUCKET"

launch() { # launch TAG SUBNET SG INSTANCE_TYPE PUBLIC_IP_FLAG
  local tag="$1" subnet="$2" sg="$3" itype="$4" pubflag="$5"
  local existing
  existing="$(aws ec2 describe-instances \
    --filters "Name=tag:Name,Values=${tag}" "Name=instance-state-name,Values=pending,running" \
    --query 'Reservations[0].Instances[0].InstanceId' --output text 2>/dev/null || true)"
  if [ "$existing" != "None" ] && [ -n "$existing" ]; then
    echo "$existing"
    return
  fi
  aws ec2 run-instances \
    --image-id "$AMI_ID" --instance-type "$itype" \
    --key-name "$KEY_NAME" --security-group-ids "$sg" --subnet-id "$subnet" \
    --iam-instance-profile "Name=${PROFILE_NAME}" \
    $pubflag \
    --metadata-options "HttpTokens=required,HttpEndpoint=enabled" \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${tag}}]" \
    --query 'Instances[0].InstanceId' --output text
}

# ---- Backend: always private-app-a, always t3.medium (it also hosts the ---
# ---- monitoring stack in §48) ----------------------------------------------
EXISTING_BACKEND="$(state_get BACKEND_INSTANCE_ID)"
if [ -z "$EXISTING_BACKEND" ]; then
  BACKEND_ID="$(launch "${PREFIX}-backend" "$PRIVATE_APP_A" "$BACKEND_SG" t3.medium "--no-associate-public-ip-address")"
  echo "Backend instance : $BACKEND_ID (private-app-a, t3.medium)"
  state_put BACKEND_INSTANCE_ID "$BACKEND_ID"
else
  BACKEND_ID="$EXISTING_BACKEND"
  echo "Backend instance : $BACKEND_ID (already running)"
fi

# ---- Frontend: subnet depends on the flag; terminate+relaunch on change ---
PREV_KIND="$(state_get FRONTEND_SUBNET_KIND)"
if [ -n "$PREV_KIND" ] && [ "$PREV_KIND" != "$FRONTEND_SUBNET_KIND" ]; then
  OLD_ID="$(state_get FRONTEND_INSTANCE_ID)"
  echo "Frontend subnet changed ($PREV_KIND -> $FRONTEND_SUBNET_KIND) — terminating old instance $OLD_ID"
  aws ec2 terminate-instances --instance-ids "$OLD_ID" >/dev/null
  aws ec2 wait instance-terminated --instance-ids "$OLD_ID"
  state_put FRONTEND_INSTANCE_ID ""
fi

EXISTING_FRONTEND="$(state_get FRONTEND_INSTANCE_ID)"
if [ -z "$EXISTING_FRONTEND" ]; then
  FRONTEND_ID="$(launch "${PREFIX}-frontend" "$FRONTEND_SUBNET" "$FRONTEND_SG" t3.micro "$FRONTEND_ASSOC_PUBLIC_IP")"
  echo "Frontend instance: $FRONTEND_ID ($FRONTEND_SUBNET_KIND subnet, t3.micro)"
  state_put FRONTEND_INSTANCE_ID "$FRONTEND_ID"
else
  FRONTEND_ID="$EXISTING_FRONTEND"
  echo "Frontend instance: $FRONTEND_ID (already running)"
fi
state_put FRONTEND_SUBNET_KIND "$FRONTEND_SUBNET_KIND"

echo "Waiting for both instances to be running and healthy…"
aws ec2 wait instance-status-ok --instance-ids "$BACKEND_ID" "$FRONTEND_ID"

BACKEND_PRIVATE_IP="$(aws ec2 describe-instances --instance-ids "$BACKEND_ID" \
  --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text)"
FRONTEND_PRIVATE_IP="$(aws ec2 describe-instances --instance-ids "$FRONTEND_ID" \
  --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text)"
FRONTEND_PUBLIC_IP="$(aws ec2 describe-instances --instance-ids "$FRONTEND_ID" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)"

state_put BACKEND_PRIVATE_IP "$BACKEND_PRIVATE_IP"
state_put FRONTEND_PRIVATE_IP "$FRONTEND_PRIVATE_IP"
state_put FRONTEND_PUBLIC_IP "$FRONTEND_PUBLIC_IP"

echo
echo "  DONE."
echo "  Backend  : $BACKEND_ID   private IP $BACKEND_PRIVATE_IP   (no public IP — SSM only)"
echo "  Frontend : $FRONTEND_ID   private IP $FRONTEND_PRIVATE_IP   public IP: ${FRONTEND_PUBLIC_IP:-<none>}"
