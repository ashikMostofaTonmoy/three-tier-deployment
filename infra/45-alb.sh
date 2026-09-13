#!/usr/bin/env bash
# =============================================================================
#  Class 6 only. An Application Load Balancer spanning both public subnets,
#  forwarding :80 to a target group containing the frontend's PRIVATE IP.
#  Once this exists and the frontend has moved to a private subnet
#  (44-ec2-instances.sh --frontend-subnet private), the ALB is the ONLY
#  public entry point into the entire app.
#
#  Usage: ./45-alb.sh
# =============================================================================
source "$(dirname "$0")/_common-vpc.sh"
export MSYS_NO_PATHCONV=1  # stop git-bash from "helpfully" rewriting /healthz into a Windows path
banner

VPC_ID="$(state_get VPC_ID)"; : "${VPC_ID:?run ./40-vpc.sh first}"
PUBLIC_A="$(state_get PUBLIC_A)"
PUBLIC_B="$(state_get PUBLIC_B)"
ALB_SG="$(state_get ALB_SG)"; : "${ALB_SG:?run ./42-security-groups.sh first}"
FRONTEND_ID="$(state_get FRONTEND_INSTANCE_ID)"; : "${FRONTEND_ID:?run ./44-ec2-instances.sh first}"
FRONTEND_KIND="$(state_get FRONTEND_SUBNET_KIND)"
if [ "$FRONTEND_KIND" != "private" ]; then
  echo "!! Frontend is currently in a '$FRONTEND_KIND' subnet."
  echo "!! Class 6 expects it private: ./44-ec2-instances.sh --frontend-subnet private"
  exit 1
fi

TG_NAME="${PREFIX}-frontend-tg"
TG_ARN="$(aws elbv2 describe-target-groups --names "$TG_NAME" --query 'TargetGroups[0].TargetGroupArn' --output text 2>/dev/null || true)"
if [ "$TG_ARN" = "None" ] || [ -z "$TG_ARN" ]; then
  TG_ARN="$(aws elbv2 create-target-group \
    --name "$TG_NAME" --protocol HTTP --port 80 --vpc-id "$VPC_ID" --target-type instance \
    --health-check-path /healthz --health-check-interval-seconds 15 \
    --healthy-threshold-count 2 --unhealthy-threshold-count 2 \
    --query 'TargetGroups[0].TargetGroupArn' --output text)"
  echo "Target group     : $TG_ARN (created)"
else
  echo "Target group     : $TG_ARN (already exists)"
fi

aws elbv2 register-targets --target-group-arn "$TG_ARN" --targets "Id=${FRONTEND_ID}" >/dev/null
echo "Registered target: $FRONTEND_ID"

ALB_NAME="${PREFIX}-alb"
ALB_ARN="$(aws elbv2 describe-load-balancers --names "$ALB_NAME" --query 'LoadBalancers[0].LoadBalancerArn' --output text 2>/dev/null || true)"
if [ "$ALB_ARN" = "None" ] || [ -z "$ALB_ARN" ]; then
  ALB_ARN="$(aws elbv2 create-load-balancer \
    --name "$ALB_NAME" --type application --scheme internet-facing \
    --subnets "$PUBLIC_A" "$PUBLIC_B" --security-groups "$ALB_SG" \
    --query 'LoadBalancers[0].LoadBalancerArn' --output text)"
  echo "ALB              : $ALB_ARN (created)"
else
  echo "ALB              : $ALB_ARN (already exists)"
fi

wait_for "ALB to become active" \
  "aws elbv2 describe-load-balancers --load-balancer-arns $ALB_ARN --query 'LoadBalancers[0].State.Code' --output text" \
  "active"

LISTENER_ARN="$(aws elbv2 describe-listeners --load-balancer-arn "$ALB_ARN" --query 'Listeners[0].ListenerArn' --output text 2>/dev/null || true)"
if [ "$LISTENER_ARN" = "None" ] || [ -z "$LISTENER_ARN" ]; then
  aws elbv2 create-listener --load-balancer-arn "$ALB_ARN" --protocol HTTP --port 80 \
    --default-actions "Type=forward,TargetGroupArn=${TG_ARN}" >/dev/null
  echo "Listener         : :80 -> $TG_NAME (created)"
else
  echo "Listener         : already exists"
fi

ALB_DNS="$(aws elbv2 describe-load-balancers --load-balancer-arns "$ALB_ARN" --query 'LoadBalancers[0].DNSName' --output text)"

state_put TG_ARN "$TG_ARN"
state_put ALB_ARN "$ALB_ARN"
state_put ALB_DNS "$ALB_DNS"

echo
echo "  DONE."
echo "  ALB DNS name: http://$ALB_DNS/"
echo "  Waiting ~30-60s for the health check to pass — then that URL is the"
echo "  ONLY way to reach the app from the internet."
