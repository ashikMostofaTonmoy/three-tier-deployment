#!/usr/bin/env bash
# =============================================================================
#  A NAT Gateway lives in a PUBLIC subnet and gives PRIVATE subnets outbound
#  internet access without ever accepting inbound connections from the
#  internet — the backend instance can still `apt-get`/`npm ci`/call
#  Open-Meteo, but nothing on the internet can initiate a connection to it.
#  That asymmetry (outbound yes, inbound no) is the entire point of a NAT.
#
#  This one NAT Gateway serves BOTH private-app subnets and BOTH private-db
#  subnets — one NAT Gateway per AZ is the real-world HA pattern (so an AZ
#  outage doesn't take out every private subnet's internet access), but this
#  lab uses one to halve the cost; noted explicitly in the README.
#
#  Usage: ./41-nat-gateway.sh
#  Takes 1-3 minutes for the NAT Gateway to become available — this script
#  waits for that before returning.
# =============================================================================
source "$(dirname "$0")/_common-vpc.sh"
banner

VPC_ID="$(state_get VPC_ID)"; : "${VPC_ID:?run ./40-vpc.sh first}"
PUBLIC_A="$(state_get PUBLIC_A)"
PRIVATE_APP_A="$(state_get PRIVATE_APP_A)"
PRIVATE_APP_B="$(state_get PRIVATE_APP_B)"
PRIVATE_DB_A="$(state_get PRIVATE_DB_A)"
PRIVATE_DB_B="$(state_get PRIVATE_DB_B)"

# ---- 1. Elastic IP for the NAT Gateway -------------------------------------
EIP_ALLOC="$(state_get EIP_ALLOC)"
if [ -z "$EIP_ALLOC" ]; then
  EIP_ALLOC="$(aws ec2 allocate-address --domain vpc \
    --tag-specifications "ResourceType=elastic-ip,Tags=[{Key=Name,Value=${PREFIX}-nat-eip}]" \
    --query 'AllocationId' --output text)"
  echo "Elastic IP       : $EIP_ALLOC (allocated)"
else
  echo "Elastic IP       : $EIP_ALLOC (already allocated)"
fi

# ---- 2. NAT Gateway ---------------------------------------------------
NAT_ID="$(aws ec2 describe-nat-gateways \
  --filter "Name=tag:Name,Values=${PREFIX}-nat" "Name=state,Values=pending,available" \
  --query 'NatGateways[0].NatGatewayId' --output text 2>/dev/null || true)"
if [ "$NAT_ID" = "None" ] || [ -z "$NAT_ID" ]; then
  NAT_ID="$(aws ec2 create-nat-gateway --subnet-id "$PUBLIC_A" --allocation-id "$EIP_ALLOC" \
    --tag-specifications "ResourceType=natgateway,Tags=[{Key=Name,Value=${PREFIX}-nat}]" \
    --query 'NatGateway.NatGatewayId' --output text)"
  echo "NAT Gateway      : $NAT_ID (creating, in $PUBLIC_A)"
else
  echo "NAT Gateway      : $NAT_ID (already exists)"
fi

wait_for "NAT Gateway to become available" \
  "aws ec2 describe-nat-gateways --nat-gateway-ids $NAT_ID --query 'NatGateways[0].State' --output text" \
  "available"

# ---- 3. Private route table: 0.0.0.0/0 -> NAT ---------------------------
PRIV_RT="$(aws ec2 describe-route-tables --filters "Name=tag:Name,Values=${PREFIX}-private-rt" \
  --query 'RouteTables[0].RouteTableId' --output text 2>/dev/null || true)"
if [ "$PRIV_RT" = "None" ] || [ -z "$PRIV_RT" ]; then
  PRIV_RT="$(aws ec2 create-route-table --vpc-id "$VPC_ID" \
    --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=${PREFIX}-private-rt}]" \
    --query 'RouteTable.RouteTableId' --output text)"
  aws ec2 create-route --route-table-id "$PRIV_RT" --destination-cidr-block 0.0.0.0/0 --nat-gateway-id "$NAT_ID" >/dev/null
  for s in "$PRIVATE_APP_A" "$PRIVATE_APP_B" "$PRIVATE_DB_A" "$PRIVATE_DB_B"; do
    aws ec2 associate-route-table --route-table-id "$PRIV_RT" --subnet-id "$s" >/dev/null
  done
  echo "Private route tbl: $PRIV_RT (created, 0.0.0.0/0 -> $NAT_ID, associated to all 4 private subnets)"
else
  echo "Private route tbl: $PRIV_RT (already exists)"
fi

state_put EIP_ALLOC "$EIP_ALLOC"
state_put NAT_ID "$NAT_ID"
state_put PRIV_RT "$PRIV_RT"

echo
echo "  DONE. Private subnets now have outbound-only internet access via $NAT_ID."
