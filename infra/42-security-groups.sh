#!/usr/bin/env bash
# =============================================================================
#  One security group per tier, chained so each only accepts traffic from the
#  hop before it — never further upstream, never from the open internet
#  unless that's genuinely the front door:
#
#    world        --80--> alb-sg        (Class 6 only; unused in Class 5)
#    world        --80--> frontend-sg   (Class 5 only: direct public IP)
#    alb-sg       --80--> frontend-sg   (Class 6 only: via the ALB instead)
#    frontend-sg  --3000-> backend-sg
#    backend-sg   --5432-> db-sg
#    (monitoring) backend-sg --9100/9113--> frontend-sg  (Prometheus scraping
#                                            the frontend's exporters, §48)
#    you (--your-ip--) --22--> frontend-sg, backend-sg    (SSH is NOT actually
#                                            used per the "pure SSM" decision,
#                                            but SSM doesn't need an inbound
#                                            rule at all — SSM Agent calls OUT
#                                            to AWS, so no port 22 rule is
#                                            opened here at all)
#
#  Usage: ./42-security-groups.sh
# =============================================================================
source "$(dirname "$0")/_common-vpc.sh"
banner

VPC_ID="$(state_get VPC_ID)"; : "${VPC_ID:?run ./40-vpc.sh first}"

make_sg() { # make_sg NAME DESCRIPTION
  local name="$1" desc="$2" id
  id="$(aws ec2 describe-security-groups --filters "Name=group-name,Values=${name}" "Name=vpc-id,Values=${VPC_ID}" \
    --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || true)"
  if [ "$id" = "None" ] || [ -z "$id" ]; then
    id="$(aws ec2 create-security-group --group-name "$name" --description "$desc" --vpc-id "$VPC_ID" \
      --query GroupId --output text)"
    echo "  + $name ($id)" >&2
  else
    echo "  = $name ($id) already exists" >&2
  fi
  echo "$id"
}

allow() { # allow SG_ID PROTO PORT SOURCE_SG_OR_CIDR DESCRIPTION
  local sg="$1" proto="$2" port="$3" src="$4" desc="$5"
  if [[ "$src" == sg-* ]]; then
    aws ec2 authorize-security-group-ingress --group-id "$sg" \
      --ip-permissions "IpProtocol=${proto},FromPort=${port},ToPort=${port},UserIdGroupPairs=[{GroupId=${src},Description='${desc}'}]" \
      >/dev/null 2>&1 && echo "    + $sg allow $proto/$port from $src ($desc)" || echo "    = $sg $proto/$port from $src already allowed"
  else
    aws ec2 authorize-security-group-ingress --group-id "$sg" \
      --ip-permissions "IpProtocol=${proto},FromPort=${port},ToPort=${port},IpRanges=[{CidrIp=${src},Description='${desc}'}]" \
      >/dev/null 2>&1 && echo "    + $sg allow $proto/$port from $src ($desc)" || echo "    = $sg $proto/$port from $src already allowed"
  fi
}

ALB_SG="$(make_sg "${PREFIX}-alb-sg" "ALB - public HTTP entry point (Class 6)")"
FRONTEND_SG="$(make_sg "${PREFIX}-frontend-sg" "Frontend tier - Nginx")"
BACKEND_SG="$(make_sg "${PREFIX}-backend-sg" "Backend tier - Node/Express")"
DB_SG="$(make_sg "${PREFIX}-db-sg" "Database tier - RDS Postgres")"

MY_IP="$(curl -s https://checkip.amazonaws.com | tr -d '[:space:]')"

echo "Rules:"
allow "$ALB_SG" tcp 80 "0.0.0.0/0" "http-public"
allow "$FRONTEND_SG" tcp 80 "0.0.0.0/0" "http-public-class5-direct"
allow "$FRONTEND_SG" tcp 80 "$ALB_SG" "http-from-alb-class6"
allow "$BACKEND_SG" tcp 3000 "$FRONTEND_SG" "api-from-frontend"
allow "$DB_SG" tcp 5432 "$BACKEND_SG" "postgres-from-backend"
# Monitoring: Prometheus (on the backend instance) scrapes the frontend's
# exporters over the private network — this rule is what makes that reachable.
allow "$FRONTEND_SG" tcp 9100 "$BACKEND_SG" "node-exporter-scrape-from-backend"
allow "$FRONTEND_SG" tcp 9113 "$BACKEND_SG" "nginx-exporter-scrape-from-backend"

state_put ALB_SG "$ALB_SG"
state_put FRONTEND_SG "$FRONTEND_SG"
state_put BACKEND_SG "$BACKEND_SG"
state_put DB_SG "$DB_SG"
state_put MY_IP "$MY_IP"

echo
echo "  DONE. ALB_SG=$ALB_SG FRONTEND_SG=$FRONTEND_SG BACKEND_SG=$BACKEND_SG DB_SG=$DB_SG"
