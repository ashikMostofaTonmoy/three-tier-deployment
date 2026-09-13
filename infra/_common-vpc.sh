#!/usr/bin/env bash
# Shared settings for the Part 5/6 (VPC networking) scripts. Sourced, not run
# directly. Deliberately separate from infra/_common.sh's state — this is a
# different VPC, different instances, different everything from Parts 1-4.

set -euo pipefail

AWS_PROFILE="${AWS_PROFILE:-ostad}"
AWS_REGION="${AWS_REGION:-ap-southeast-1}"
export AWS_PROFILE AWS_REGION
export PYTHONUTF8=1 PYTHONIOENCODING=utf-8

PREFIX="${PREFIX:-three-tier-vpc}"
VPC_CIDR="10.0.0.0/16"
KEY_NAME="${PREFIX}-key"

STATE_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/.lab-state-vpc"
KEY_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/${KEY_NAME}.pem"

aws() { command aws --region "$AWS_REGION" --profile "$AWS_PROFILE" "$@"; }

state_put() {
  touch "$STATE_FILE"
  grep -v "^$1=" "$STATE_FILE" > "$STATE_FILE.tmp" 2>/dev/null || true
  mv "$STATE_FILE.tmp" "$STATE_FILE"
  echo "$1=$2" >> "$STATE_FILE"
}

state_get() {
  [ -f "$STATE_FILE" ] && sed -n "s/^$1=//p" "$STATE_FILE" | tail -1
}

banner() {
  local acct
  acct="$(aws sts get-caller-identity --query Account --output text)"
  echo "=================================================================="
  echo "  profile : $AWS_PROFILE"
  echo "  account : $acct"
  echo "  region  : $AWS_REGION"
  echo "  VPC CIDR: $VPC_CIDR"
  echo "=================================================================="
}

# Wait for a NAT Gateway (or anything with --query returning a state string)
# to reach a target state, polling every 10s. Used because NAT Gateway
# provisioning takes 1-3 minutes and there's no `aws ec2 wait` for it.
# Run a local script FILE on instance INSTANCE_ID via SSM (no SSH, ever —
# the "pure SSM" decision). Streams the real stdout/stderr back and fails
# loudly (non-zero exit) if the remote command didn't succeed.
ssm_run() { # ssm_run INSTANCE_ID FILE
  local iid="$1" file="$2" params cmd_id status
  params="$(mktemp "${TMPDIR:-/tmp}/ssm-params.XXXXXX.json" 2>/dev/null || echo "$(dirname "$file")/.ssm-params.json")"
  python3 -c "
import json,sys
lines = open(sys.argv[1], encoding='utf-8').read().split('\n')
json.dump({'commands': lines}, open(sys.argv[2], 'w'))
" "$file" "$params" 2>/dev/null || \
  { echo "python3 not found — falling back to a single-line command" >&2; }
  cmd_id="$(aws ssm send-command --instance-ids "$iid" --document-name AWS-RunShellScript \
    --parameters "file://$(cygpath -w "$params" 2>/dev/null || echo "$params")" \
    --timeout-seconds 900 --query Command.CommandId --output text)"
  aws ssm wait command-executed --command-id "$cmd_id" --instance-id "$iid" 2>/dev/null || true
  status="$(aws ssm get-command-invocation --command-id "$cmd_id" --instance-id "$iid" --query Status --output text)"
  aws ssm get-command-invocation --command-id "$cmd_id" --instance-id "$iid" --query StandardOutputContent --output text
  if [ "$status" != "Success" ]; then
    echo "--- stderr ---" >&2
    aws ssm get-command-invocation --command-id "$cmd_id" --instance-id "$iid" --query StandardErrorContent --output text >&2
    rm -f "$params"
    return 1
  fi
  rm -f "$params"
}

wait_for() { # wait_for "description" "aws-query-command..." "target-state"
  local desc="$1" cmd="$2" target="$3" state=""
  echo -n "waiting for $desc"
  for _ in $(seq 1 60); do
    state="$(eval "$cmd" 2>/dev/null || true)"
    [ "$state" = "$target" ] && { echo " -> $state"; return 0; }
    echo -n "."
    sleep 10
  done
  echo " -> gave up (last state: $state)"
  return 1
}
