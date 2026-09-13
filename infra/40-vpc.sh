#!/usr/bin/env bash
# =============================================================================
#  A custom VPC for the three-tier app, laid out across 2 Availability Zones:
#    public-a / public-b        10.0.0.0/24  / 10.0.1.0/24   -> Internet Gateway
#    private-app-a / -b         10.0.10.0/24 / 10.0.11.0/24  -> (routed to NAT in 41-nat-gateway.sh)
#    private-db-a / -b          10.0.20.0/24 / 10.0.21.0/24  -> (same private route table)
#
#  A subnet is "public" or "private" ONLY because of its route table — this
#  script gives the public ones a route to the Internet Gateway; the private
#  ones get no internet route at all until 41-nat-gateway.sh runs.
#
#  Usage: ./40-vpc.sh
#  Idempotent: safe to re-run, reuses anything already tagged with our names.
# =============================================================================
source "$(dirname "$0")/_common-vpc.sh"
banner

# ---- 1. VPC ----------------------------------------------------------------
VPC_ID="$(aws ec2 describe-vpcs --filters "Name=tag:Name,Values=${PREFIX}" \
  --query 'Vpcs[0].VpcId' --output text 2>/dev/null || true)"
if [ "$VPC_ID" = "None" ] || [ -z "$VPC_ID" ]; then
  VPC_ID="$(aws ec2 create-vpc --cidr-block "$VPC_CIDR" \
    --tag-specifications "ResourceType=vpc,Tags=[{Key=Name,Value=${PREFIX}}]" \
    --query 'Vpc.VpcId' --output text)"
  aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-hostnames "{\"Value\":true}"
  echo "VPC              : $VPC_ID (created)"
else
  echo "VPC              : $VPC_ID (already exists)"
fi

# ---- 2. Two Availability Zones ----------------------------------------------
AZ_A="$(aws ec2 describe-availability-zones --query 'AvailabilityZones[0].ZoneName' --output text)"
AZ_B="$(aws ec2 describe-availability-zones --query 'AvailabilityZones[1].ZoneName' --output text)"
echo "AZs              : $AZ_A / $AZ_B"

# ---- 3. Six subnets ---------------------------------------------------------
make_subnet() { # make_subnet NAME CIDR AZ
  local name="$1" cidr="$2" az="$3" id
  id="$(aws ec2 describe-subnets --filters "Name=tag:Name,Values=${name}" "Name=vpc-id,Values=${VPC_ID}" \
    --query 'Subnets[0].SubnetId' --output text 2>/dev/null || true)"
  if [ "$id" = "None" ] || [ -z "$id" ]; then
    id="$(aws ec2 create-subnet --vpc-id "$VPC_ID" --cidr-block "$cidr" --availability-zone "$az" \
      --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=${name}}]" \
      --query 'Subnet.SubnetId' --output text)"
    echo "  + $name ($id, $cidr, $az)" >&2
  else
    echo "  = $name ($id) already exists" >&2
  fi
  echo "$id"
}

PUBLIC_A="$(make_subnet "${PREFIX}-public-a" 10.0.0.0/24 "$AZ_A")"
PUBLIC_B="$(make_subnet "${PREFIX}-public-b" 10.0.1.0/24 "$AZ_B")"
PRIVATE_APP_A="$(make_subnet "${PREFIX}-private-app-a" 10.0.10.0/24 "$AZ_A")"
PRIVATE_APP_B="$(make_subnet "${PREFIX}-private-app-b" 10.0.11.0/24 "$AZ_B")"
PRIVATE_DB_A="$(make_subnet "${PREFIX}-private-db-a" 10.0.20.0/24 "$AZ_A")"
PRIVATE_DB_B="$(make_subnet "${PREFIX}-private-db-b" 10.0.21.0/24 "$AZ_B")"

# Public subnets hand out public IPs automatically — that's the other half of
# "public" (a route to the internet is useless without a public IP to use it).
for s in "$PUBLIC_A" "$PUBLIC_B"; do
  aws ec2 modify-subnet-attribute --subnet-id "$s" --map-public-ip-on-launch >/dev/null
done

# ---- 4. Internet Gateway -----------------------------------------------
IGW_ID="$(aws ec2 describe-internet-gateways --filters "Name=tag:Name,Values=${PREFIX}-igw" \
  --query 'InternetGateways[0].InternetGatewayId' --output text 2>/dev/null || true)"
if [ "$IGW_ID" = "None" ] || [ -z "$IGW_ID" ]; then
  IGW_ID="$(aws ec2 create-internet-gateway \
    --tag-specifications "ResourceType=internet-gateway,Tags=[{Key=Name,Value=${PREFIX}-igw}]" \
    --query 'InternetGateway.InternetGatewayId' --output text)"
  aws ec2 attach-internet-gateway --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID"
  echo "Internet Gateway : $IGW_ID (created + attached)"
else
  echo "Internet Gateway : $IGW_ID (already exists)"
fi

# ---- 5. Public route table: 0.0.0.0/0 -> IGW --------------------------
PUB_RT="$(aws ec2 describe-route-tables --filters "Name=tag:Name,Values=${PREFIX}-public-rt" \
  --query 'RouteTables[0].RouteTableId' --output text 2>/dev/null || true)"
if [ "$PUB_RT" = "None" ] || [ -z "$PUB_RT" ]; then
  PUB_RT="$(aws ec2 create-route-table --vpc-id "$VPC_ID" \
    --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=${PREFIX}-public-rt}]" \
    --query 'RouteTable.RouteTableId' --output text)"
  aws ec2 create-route --route-table-id "$PUB_RT" --destination-cidr-block 0.0.0.0/0 --gateway-id "$IGW_ID" >/dev/null
  aws ec2 associate-route-table --route-table-id "$PUB_RT" --subnet-id "$PUBLIC_A" >/dev/null
  aws ec2 associate-route-table --route-table-id "$PUB_RT" --subnet-id "$PUBLIC_B" >/dev/null
  echo "Public route tbl : $PUB_RT (created, 0.0.0.0/0 -> $IGW_ID, associated to public-a/b)"
else
  echo "Public route tbl : $PUB_RT (already exists)"
fi

state_put VPC_ID "$VPC_ID"
state_put AZ_A "$AZ_A"
state_put AZ_B "$AZ_B"
state_put PUBLIC_A "$PUBLIC_A"
state_put PUBLIC_B "$PUBLIC_B"
state_put PRIVATE_APP_A "$PRIVATE_APP_A"
state_put PRIVATE_APP_B "$PRIVATE_APP_B"
state_put PRIVATE_DB_A "$PRIVATE_DB_A"
state_put PRIVATE_DB_B "$PRIVATE_DB_B"
state_put IGW_ID "$IGW_ID"
state_put PUB_RT "$PUB_RT"

echo
echo "  DONE. VPC_ID=$VPC_ID"
echo "  Private subnets have NO internet route yet — that's next: ./41-nat-gateway.sh"
