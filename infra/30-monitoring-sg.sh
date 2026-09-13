#!/usr/bin/env bash
# =============================================================================
#  Open the three ports the monitoring stack needs, on the SAME security
#  group infra/01-ec2.sh already created. No new security group, and nothing
#  new for cleanup: infra/teardown.sh already deletes this whole SG.
#
#    9090  Prometheus UI     — your IP only (Prometheus has NO built-in auth)
#    9093  Alertmanager UI   — your IP only (same: no auth)
#    3001  Grafana           — the whole internet (Grafana DOES have a login)
#
#  Usage: ./30-monitoring-sg.sh
# =============================================================================
source "$(dirname "$0")/_common.sh"
banner

SG_ID="$(state_get SG_ID)"
: "${SG_ID:?run infra/01-ec2.sh first}"
MY_IP="$(curl -s https://checkip.amazonaws.com | tr -d '[:space:]')"

add_rule() { # add_rule PORT CIDR DESCRIPTION
  aws ec2 authorize-security-group-ingress --group-id "$SG_ID" \
    --ip-permissions "IpProtocol=tcp,FromPort=$1,ToPort=$1,IpRanges=[{CidrIp=$2,Description=$3}]" \
    >/dev/null 2>&1 && echo "  + port $1 from $2 ($3)" \
    || echo "  = port $1 from $2 already allowed"
}

add_rule 9090 "${MY_IP}/32" "prometheus-ui-my-ip"
add_rule 9093 "${MY_IP}/32" "alertmanager-ui-my-ip"
add_rule 3001 "0.0.0.0/0"   "grafana-public"

echo
echo "  DONE. Security group $SG_ID now also allows:"
aws ec2 describe-security-groups --group-ids "$SG_ID" \
  --query 'SecurityGroups[0].IpPermissions[?FromPort==`9090` || FromPort==`9093` || FromPort==`3001`]' \
  --output table
