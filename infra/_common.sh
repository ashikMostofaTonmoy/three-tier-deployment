#!/usr/bin/env bash
# Shared settings + helpers for the infra scripts. Sourced, not run directly.

set -euo pipefail

# Which AWS account to talk to. Override with:  AWS_PROFILE=other ./01-ec2.sh
AWS_PROFILE="${AWS_PROFILE:-ostad}"
AWS_REGION="${AWS_REGION:-ap-southeast-1}"
export AWS_PROFILE AWS_REGION

# Names every script agrees on. Change the prefix if you want a second stack.
PREFIX="${PREFIX:-three-tier}"
KEY_NAME="${PREFIX}-key"
SG_NAME="${PREFIX}-sg"
ROLE_NAME="${PREFIX}-ssm-role"
PROFILE_NAME="${PREFIX}-ssm-profile"
INSTANCE_TAG="${PREFIX}-web"
CICD_ROLE_NAME="${PREFIX}-deploy-role"

# Where scripts read/write the IDs they create.
STATE_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/.lab-state"
KEY_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/${KEY_NAME}.pem"

aws() { command aws --region "$AWS_REGION" --profile "$AWS_PROFILE" "$@"; }

state_put() { # state_put KEY VALUE
  touch "$STATE_FILE"
  grep -v "^$1=" "$STATE_FILE" > "$STATE_FILE.tmp" 2>/dev/null || true
  mv "$STATE_FILE.tmp" "$STATE_FILE"
  echo "$1=$2" >> "$STATE_FILE"
}

state_get() { # state_get KEY
  [ -f "$STATE_FILE" ] && sed -n "s/^$1=//p" "$STATE_FILE" | tail -1
}

banner() {
  local acct
  acct="$(aws sts get-caller-identity --query Account --output text)"
  echo "=================================================================="
  echo "  profile : $AWS_PROFILE"
  echo "  account : $acct"
  echo "  region  : $AWS_REGION"
  echo "=================================================================="
}
