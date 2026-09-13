#!/usr/bin/env bash
# =============================================================================
#  Install a GitHub Actions self-hosted runner ON the instance from
#  infra/01-ec2.sh, and register it against your repo. One-time, outside CI —
#  the workflow that later USES this runner never installs or registers it.
#
#  Usage:
#    ./21-self-hosted-runner.sh <owner>/<repo>
#    e.g. ./21-self-hosted-runner.sh ashikMostofaTonmoy/three-tier-deployment
#
#  Requires: `gh` CLI logged in with access to the repo (to mint a short-lived
#  runner registration token — never stored anywhere, expires in ~1 hour).
# =============================================================================
source "$(dirname "$0")/_common.sh"

GH_REPO="${1:?pass your GitHub owner/repo}"
banner

INSTANCE_ID="$(state_get INSTANCE_ID)"
: "${INSTANCE_ID:?run infra/01-ec2.sh first}"

RUNNER_VERSION="$(gh api repos/actions/runner/releases/latest --jq '.tag_name' | sed 's/^v//')"
echo "Runner version   : $RUNNER_VERSION"

REG_TOKEN="$(gh api -X POST "repos/${GH_REPO}/actions/runners/registration-token" --jq '.token')"
echo "Registration tok : (fetched, expires in ~1 hour, never stored)"

# NOTE on running as root: SSM commands execute as root, and this is a
# throwaway lab VM, so we allow the runner to install/run as root
# (RUNNER_ALLOW_RUNASROOT=1) to keep this script simple. In a real
# environment you would create a dedicated non-root user for the runner.
cat > /tmp/.runner-install.sh <<REMOTE
set -e
export RUNNER_ALLOW_RUNASROOT=1
mkdir -p /opt/actions-runner && cd /opt/actions-runner
if [ ! -f config.sh ]; then
  curl -fsSL -o runner.tar.gz \
    "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz"
  tar xzf runner.tar.gz
  rm -f runner.tar.gz
fi
./config.sh remove --token "${REG_TOKEN}" >/dev/null 2>&1 || true
./config.sh --url "https://github.com/${GH_REPO}" --token "${REG_TOKEN}" \
  --unattended --replace --name three-tier-runner --labels three-tier-lab
./svc.sh install root
./svc.sh start
./svc.sh status
REMOTE

echo "Installing + starting the runner service on ${INSTANCE_ID} (via SSM)…"
PARAMS_FILE=/tmp/.runner-ssm-params.json
python3 - "$PARAMS_FILE" <<'PY'
import json, sys
with open('/tmp/.runner-install.sh') as f:
    lines = f.read().split('\n')
json.dump({"commands": lines}, open(sys.argv[1], 'w'))
PY

CMD_ID="$(aws ssm send-command --instance-ids "$INSTANCE_ID" \
  --document-name AWS-RunShellScript --timeout-seconds 300 \
  --parameters "file://${PARAMS_FILE}" --query Command.CommandId --output text)"
aws ssm wait command-executed --command-id "$CMD_ID" --instance-id "$INSTANCE_ID" 2>/dev/null || true
aws ssm get-command-invocation --command-id "$CMD_ID" --instance-id "$INSTANCE_ID" \
  --query StandardOutputContent --output text
STATUS="$(aws ssm get-command-invocation --command-id "$CMD_ID" --instance-id "$INSTANCE_ID" --query Status --output text)"
rm -f /tmp/.runner-install.sh "$PARAMS_FILE"
[ "$STATUS" = "Success" ] || { echo "runner install FAILED (status=$STATUS)"; exit 1; }

state_put GH_REPO "$GH_REPO"
state_put RUNNER_INSTALLED true

echo
echo "  DONE. Check it registered:"
echo "    gh api repos/${GH_REPO}/actions/runners --jq '.runners[] | {name,status,busy}'"
