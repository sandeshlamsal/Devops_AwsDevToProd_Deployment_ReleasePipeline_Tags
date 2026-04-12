#!/bin/bash
# teardown.sh <env> <account_id> [region]
#
# Destroys ALL resources for a given environment in the correct order.
# Safe to re-run — each step checks for existence before acting.
#
# ┌─────────────────────────────────────────────────────────────────────────┐
# │  WHY THIS RUNS LOCALLY (not via GitHub Actions)                         │
# │                                                                         │
# │  terraform destroy removes the IAM OIDC role that GitHub Actions uses   │
# │  to authenticate. Once the role is gone, no workflow can run again.     │
# │  Teardown is therefore the ONE permitted local operation in this repo.  │
# └─────────────────────────────────────────────────────────────────────────┘
#
# Usage:
#   AWS_PROFILE=dev-admin ./scripts/teardown.sh dev  648426766457
#   AWS_PROFILE=qa-admin  ./scripts/teardown.sh qa   506250256146
#   AWS_PROFILE=prod-admin ./scripts/teardown.sh prod 429429082896
#
# Resources destroyed (in order):
#   1. Kubernetes namespace + all workloads  (prevents orphaned NLB)
#   2. terraform destroy                     (EKS, VPC, IAM roles, OIDC provider)
#   3. S3 state bucket                       (emptied then deleted)

set -euo pipefail

ENV="${1:-}"
ACCOUNT_ID="${2:-}"
REGION="${3:-us-east-1}"

if [ -z "$ENV" ] || [ -z "$ACCOUNT_ID" ]; then
  echo "Usage: $0 <env> <account_id> [region]"
  echo "  AWS_PROFILE=dev-admin  $0 dev  648426766457"
  echo "  AWS_PROFILE=qa-admin   $0 qa   506250256146"
  echo "  AWS_PROFILE=prod-admin $0 prod 429429082896"
  exit 1
fi

BUCKET="tfstate-nginx-release-${ENV}-${ACCOUNT_ID}"
CLUSTER_NAME="eks-${ENV}"
NAMESPACE="release-app"
TF_DIR="terraform/${ENV}"

echo ""
echo "Teardown: environment=${ENV}  account=${ACCOUNT_ID}  region=${REGION}"
echo "────────────────────────────────────────────────────────────────────────"
echo ""
echo "WARNING: This will permanently delete all ${ENV} infrastructure."
echo "         The action CANNOT be undone."
echo ""
read -rp "Type the environment name to confirm: " CONFIRM
if [ "$CONFIRM" != "$ENV" ]; then
  echo "Aborted."
  exit 1
fi

# ─── Verify correct AWS account ──────────────────────────────────────────────
CURRENT_ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
if [ "$CURRENT_ACCOUNT" != "$ACCOUNT_ID" ]; then
  echo "ERROR: Credentials are for account $CURRENT_ACCOUNT, expected $ACCOUNT_ID"
  echo "       Set AWS_PROFILE=<env>-admin and retry."
  exit 1
fi
echo "Account verified: $CURRENT_ACCOUNT"
echo ""

# ─── Step 1: Delete Kubernetes resources ─────────────────────────────────────
# Must happen BEFORE terraform destroy — the LoadBalancer service creates an
# AWS NLB. Deleting it via kubectl lets EKS clean up the NLB cleanly.
# If we destroy EKS first the NLB becomes an orphan and must be deleted manually.
echo "Step 1 — Delete Kubernetes resources (namespace: ${NAMESPACE})"

if aws eks describe-cluster --name "$CLUSTER_NAME" --region "$REGION" \
     --query 'cluster.status' --output text 2>/dev/null | grep -q ACTIVE; then

  aws eks update-kubeconfig \
    --name "$CLUSTER_NAME" \
    --region "$REGION" \
    --alias "teardown-${ENV}" 2>/dev/null

  if kubectl get namespace "$NAMESPACE" &>/dev/null; then
    echo "  Deleting namespace ${NAMESPACE} (includes Deployment, Service, ConfigMap, Secrets)..."
    kubectl delete namespace "$NAMESPACE" --timeout=120s
    echo "  Namespace deleted — NLB cleanup triggered."
    echo "  Waiting 30s for NLB to de-register..."
    sleep 30
  else
    echo "  Namespace ${NAMESPACE} not found — skipping."
  fi
else
  echo "  Cluster ${CLUSTER_NAME} not found or not active — skipping kubectl step."
fi
echo ""

# ─── Step 2: terraform destroy ───────────────────────────────────────────────
echo "Step 2 — terraform destroy (VPC, EKS, IAM roles, OIDC provider)"

if [ ! -d "$TF_DIR" ]; then
  echo "  ERROR: Directory $TF_DIR not found."
  exit 1
fi

cd "$TF_DIR"

# Init with backend to load existing state
terraform init -reconfigure

echo "  Running terraform destroy (this takes ~10 min)..."
terraform destroy -auto-approve

cd - > /dev/null
echo "  terraform destroy complete."
echo ""

# ─── Step 3: Delete S3 state bucket ──────────────────────────────────────────
# Terraform does not manage the bucket itself — bootstrap.sh created it.
# Must empty the bucket (including all versions) before deleting.
echo "Step 3 — Delete S3 state bucket: ${BUCKET}"

if aws s3api head-bucket --bucket "$BUCKET" 2>/dev/null; then
  echo "  Removing all object versions and delete markers..."
  # Remove all versioned objects
  aws s3api list-object-versions --bucket "$BUCKET" \
    --query 'Versions[].{Key:Key,VersionId:VersionId}' \
    --output json 2>/dev/null | \
    jq -r '.[] | "--delete Objects=[{Key=\(.Key),VersionId=\(.VersionId)}]"' | \
    xargs -I{} aws s3api delete-objects --bucket "$BUCKET" {} 2>/dev/null || true

  # Remove all delete markers
  aws s3api list-object-versions --bucket "$BUCKET" \
    --query 'DeleteMarkers[].{Key:Key,VersionId:VersionId}' \
    --output json 2>/dev/null | \
    jq -r '.[] | "--delete Objects=[{Key=\(.Key),VersionId=\(.VersionId)}]"' | \
    xargs -I{} aws s3api delete-objects --bucket "$BUCKET" {} 2>/dev/null || true

  echo "  Deleting bucket ${BUCKET}..."
  aws s3api delete-bucket --bucket "$BUCKET" --region "$REGION"
  echo "  Bucket deleted."
else
  echo "  Bucket ${BUCKET} not found — skipping."
fi
echo ""

# ─── Done ─────────────────────────────────────────────────────────────────────
echo "════════════════════════════════════════════════════════════════════════"
echo "Teardown complete for ${ENV}."
echo ""
echo "Remaining manual cleanup (not automated):"
echo ""
echo "  GHCR images:"
echo "    GitHub → Packages → nginx-release → delete all ${ENV}_* tags"
echo "    URL: https://github.com/sandeshlamsal?tab=packages"
echo ""
echo "  GitHub Environments (optional — reusable across runs):"
echo "    To remove: edit terraform/github/terraform.tfvars → set reviewer"
echo "    lists to [] → push to main → terraform-github.yml will update them."
echo "    Or delete manually: repo → Settings → Environments."
echo ""
echo "  CloudWatch log groups (if not deleted by terraform destroy):"
echo "    aws logs describe-log-groups --log-group-name-prefix /aws/eks/${CLUSTER_NAME} \\"
echo "      --region ${REGION} --query 'logGroups[].logGroupName' --output text"
echo ""
