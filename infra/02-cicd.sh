#!/usr/bin/env bash
# =============================================================================
#  Set up passwordless CI/CD for GitHub Actions:
#    - an S3 bucket            where each build is staged as a .tgz
#    - a GitHub OIDC provider   so Actions can get short-lived AWS credentials
#                               (no access keys stored in the repo)
#    - an IAM role              Actions assumes: put builds in S3 + tell the
#                               instance (via SSM) to pull and go live
#    - one extra permission     on the instance's own role: read that S3 bucket
#
#  Run this AFTER infra/01-ec2.sh. Prints the values you paste into
#  GitHub -> repo -> Settings -> Secrets and variables -> Actions -> Variables.
#
#  Usage:  ./02-cicd.sh <github-owner/repo>
#  e.g.    ./02-cicd.sh ashikMostofaTonmoy/three-tier-deployment
# =============================================================================
source "$(dirname "$0")/_common.sh"

GH_REPO="${1:?pass your GitHub owner/repo, e.g. ashikMostofaTonmoy/three-tier-deployment}"
banner

ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"
BUCKET="${PREFIX}-deploy-${ACCOUNT}"
OIDC_HOST="token.actions.githubusercontent.com"
OIDC_ARN="arn:aws:iam::${ACCOUNT}:oidc-provider/${OIDC_HOST}"
INSTANCE_ID="$(state_get INSTANCE_ID)"
SSM_ROLE="$(state_get ROLE_NAME)"      # the instance's role, from 01-ec2.sh
: "${INSTANCE_ID:?run infra/01-ec2.sh first}"

# ---- 1. S3 staging bucket -------------------------------------------------
if aws s3api head-bucket --bucket "$BUCKET" 2>/dev/null; then
  echo "S3 bucket        : $BUCKET (already exists)"
else
  aws s3api create-bucket --bucket "$BUCKET" \
    --create-bucket-configuration LocationConstraint="$AWS_REGION" >/dev/null
  aws s3api put-public-access-block --bucket "$BUCKET" \
    --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
  aws s3api put-bucket-lifecycle-configuration --bucket "$BUCKET" \
    --lifecycle-configuration '{"Rules":[{"ID":"expire-old-builds","Status":"Enabled","Filter":{"Prefix":"releases/"},"Expiration":{"Days":14}}]}'
  echo "S3 bucket        : $BUCKET (created, private, 14-day cleanup)"
fi

# ---- 2. GitHub OIDC provider (reuse if the account already has one) -----
CREATED_OIDC=false
if aws iam get-open-id-connect-provider --open-id-connect-provider-arn "$OIDC_ARN" >/dev/null 2>&1; then
  echo "OIDC provider    : $OIDC_HOST (already exists — reusing)"
else
  aws iam create-open-id-connect-provider \
    --url "https://${OIDC_HOST}" \
    --client-id-list "sts.amazonaws.com" \
    --thumbprint-list 6938fd4d98bab03faadb97b34396831e3780aea1 1c58a3a8518e8759bf075b76b750d4f2df264fcd >/dev/null
  CREATED_OIDC=true
  echo "OIDC provider    : $OIDC_HOST (created)"
fi

# ---- 3. IAM role that GitHub Actions assumes --------------------------
# The real guard is the clean "repository" claim. AWS also insists the trust
# policy constrain "sub", so we allow both sub shapes: the plain one, and the
# one some accounts emit with immutable numeric IDs
# (repo:owner@123/name@456:...).
GH_OWNER="${GH_REPO%%/*}"
GH_NAME="${GH_REPO##*/}"
TRUST="$(cat <<JSON
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Federated": "${OIDC_ARN}" },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {
        "${OIDC_HOST}:aud": "sts.amazonaws.com",
        "${OIDC_HOST}:repository": "${GH_REPO}"
      },
      "StringLike": {
        "${OIDC_HOST}:sub": [
          "repo:${GH_REPO}:*",
          "repo:${GH_OWNER}@*/${GH_NAME}@*:*"
        ]
      }
    }
  }]
}
JSON
)"

if aws iam get-role --role-name "$CICD_ROLE_NAME" >/dev/null 2>&1; then
  aws iam update-assume-role-policy --role-name "$CICD_ROLE_NAME" --policy-document "$TRUST"
  echo "CI/CD role       : $CICD_ROLE_NAME (trust policy updated)"
else
  aws iam create-role --role-name "$CICD_ROLE_NAME" \
    --description "GitHub Actions deploy role for ${GH_REPO}" \
    --assume-role-policy-document "$TRUST" >/dev/null
  echo "CI/CD role       : $CICD_ROLE_NAME (created)"
fi

aws iam put-role-policy --role-name "$CICD_ROLE_NAME" --policy-name deploy \
  --policy-document "$(cat <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    { "Sid": "StageBuildInS3", "Effect": "Allow",
      "Action": ["s3:PutObject","s3:GetObject"],
      "Resource": "arn:aws:s3:::${BUCKET}/*" },
    { "Sid": "TellInstanceToDeploy", "Effect": "Allow",
      "Action": "ssm:SendCommand",
      "Resource": [
        "arn:aws:ec2:${AWS_REGION}:${ACCOUNT}:instance/${INSTANCE_ID}",
        "arn:aws:ssm:${AWS_REGION}::document/AWS-RunShellScript"
      ] },
    { "Sid": "WatchTheCommand", "Effect": "Allow",
      "Action": ["ssm:GetCommandInvocation","ssm:ListCommandInvocations"],
      "Resource": "*" },
    { "Sid": "FindThePublicIp", "Effect": "Allow",
      "Action": "ec2:DescribeInstances",
      "Resource": "*" }
  ]
}
JSON
)"
echo "CI/CD role       : inline 'deploy' policy attached"

# ---- 4. Let the INSTANCE read the staging bucket -------------------
aws iam put-role-policy --role-name "$SSM_ROLE" --policy-name read-deploy-bucket \
  --policy-document "$(cat <<JSON
{
  "Version": "2012-10-17",
  "Statement": [{ "Effect": "Allow", "Action": "s3:GetObject",
    "Resource": "arn:aws:s3:::${BUCKET}/*" }]
}
JSON
)"
echo "Instance role    : may now read s3://${BUCKET}"

ROLE_ARN="arn:aws:iam::${ACCOUNT}:role/${CICD_ROLE_NAME}"
state_put BUCKET "$BUCKET"
state_put CICD_ROLE_ARN "$ROLE_ARN"
state_put CREATED_OIDC "$CREATED_OIDC"

cat <<EOF

  DONE. Set these as GitHub Actions *Variables* (not secrets) on ${GH_REPO}:

    gh variable set AWS_REGION      --body "${AWS_REGION}"
    gh variable set AWS_ROLE_ARN    --body "${ROLE_ARN}"
    gh variable set DEPLOY_BUCKET   --body "${BUCKET}"
    gh variable set EC2_INSTANCE_ID --body "${INSTANCE_ID}"

EOF
