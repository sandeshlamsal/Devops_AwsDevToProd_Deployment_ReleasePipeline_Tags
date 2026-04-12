#!/bin/bash
# bootstrap.sh <env> <account_id> [region]
#
# One-time bootstrap per AWS account.
# Creates the S3 state bucket and the GitHub Actions OIDC IAM role —
# the minimum needed before GitHub Actions can take over.
#
# State locking uses S3 native conditional writes (Terraform >= 1.10).
# No DynamoDB table is required.
#
# Run this ONCE per environment with temporary admin credentials.
# All subsequent infrastructure changes must go through GitHub Actions.
#
# Usage:
#   ./scripts/bootstrap.sh dev  648426766457
#   ./scripts/bootstrap.sh qa   506250256146
#   ./scripts/bootstrap.sh prod 429429082896

set -euo pipefail

ENV="${1:-}"
ACCOUNT_ID="${2:-}"
REGION="${3:-us-east-1}"

if [ -z "$ENV" ] || [ -z "$ACCOUNT_ID" ]; then
  echo "Usage: $0 <env> <account_id> [region]"
  echo "  $0 dev  648426766457"
  echo "  $0 qa   506250256146"
  echo "  $0 prod 429429082896"
  exit 1
fi

BUCKET="tfstate-nginx-release-${ENV}-${ACCOUNT_ID}"
TF_DIR="terraform/${ENV}"

echo ""
echo "Bootstrap: environment=${ENV}  account=${ACCOUNT_ID}  region=${REGION}"
echo "────────────────────────────────────────────────────────────────────────"

# ─── Verify correct AWS account ──────────────────────────────────────────────
CURRENT_ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
if [ "$CURRENT_ACCOUNT" != "$ACCOUNT_ID" ]; then
  echo "ERROR: Current AWS credentials are for account $CURRENT_ACCOUNT"
  echo "       Expected account $ACCOUNT_ID for environment $ENV"
  echo "       Switch your AWS profile/credentials and retry."
  exit 1
fi
echo "Account verified: $CURRENT_ACCOUNT"

# ─── S3 state bucket ─────────────────────────────────────────────────────────
if aws s3api head-bucket --bucket "$BUCKET" 2>/dev/null; then
  echo "S3 bucket already exists: $BUCKET"
else
  echo "Creating S3 bucket: $BUCKET"
  if [ "$REGION" = "us-east-1" ]; then
    aws s3api create-bucket --bucket "$BUCKET" --region "$REGION"
  else
    aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" \
      --create-bucket-configuration LocationConstraint="$REGION"
  fi
  aws s3api put-bucket-versioning \
    --bucket "$BUCKET" \
    --versioning-configuration Status=Enabled
  aws s3api put-bucket-encryption \
    --bucket "$BUCKET" \
    --server-side-encryption-configuration \
    '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
  aws s3api put-public-access-block \
    --bucket "$BUCKET" \
    --public-access-block-configuration \
    "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"
  echo "S3 bucket created: $BUCKET"
fi

# ─── Bootstrap OIDC provider + IAM role via Terraform (one-time) ─────────────
echo ""
echo "Running terraform init + apply -target=module.iam_oidc ..."
echo "This creates the GitHub Actions OIDC provider and IAM role."
echo ""

cd "$TF_DIR"
terraform init
terraform apply -target=module.iam_oidc -auto-approve

echo ""
echo "────────────────────────────────────────────────────────────────────────"
echo "Bootstrap complete for ${ENV}."
echo ""
echo "Next steps:"
echo ""
echo "  1. Copy the role ARN below and add it as a GitHub Actions secret:"
terraform output github_actions_role_arn
echo ""
echo "     Secret name: $(echo $ENV | tr '[:lower:]' '[:upper:]')_IAM_ROLE_ARN"
echo ""
echo "  2. Create GitHub Environment '${ENV}-terraform' in:"
echo "     Settings → Environments → New environment"
echo "     (Add required reviewers for qa/prod)"
echo ""
echo "  3. Once secrets are set, trigger the workflow from GitHub Actions UI:"
echo "     Actions → 'Terraform — $(echo $ENV | tr '[:lower:]' '[:upper:]')' → Run workflow → action: apply"
echo ""
echo "  All subsequent infra changes go through GitHub Actions only."
