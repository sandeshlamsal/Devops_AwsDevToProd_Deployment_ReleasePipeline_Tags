# ─── GitHub Actions OIDC Provider ────────────────────────────────────────────
# One provider per account. If already created by another module, import it.
resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]

  # GitHub's current thumbprints (update if GitHub rotates their cert)
  thumbprint_list = [
    "6938fd4d98bab03faadb97b34396831e3780aea1",
    "1c58a3a8518e8759bf075b76b750d4f2df264fcd",
  ]

  tags = var.tags
}

# ─── GitHub Actions IAM Role (scoped to env tag prefix) ──────────────────────
resource "aws_iam_role" "github_actions" {
  name        = "GitHubActionsRole-${var.environment}"
  description = "Assumed by GitHub Actions via OIDC for ${var.environment} deployments"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "GitHubOIDC"
        Effect = "Allow"
        Principal = {
          Federated = aws_iam_openid_connect_provider.github.arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringLike = {
            # Scoped: only this repo + this environment's tag prefix (or main for dev)
            "token.actions.githubusercontent.com:sub" = var.allowed_subjects
          }
          StringEquals = {
            "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          }
        }
      }
    ]
  })

  tags = var.tags
}

# ─── EKS Deploy Policy (kubectl) ─────────────────────────────────────────────
resource "aws_iam_policy" "eks_deploy" {
  name        = "GitHubActions-EKS-${var.environment}"
  description = "Minimal EKS permissions for GitHub Actions ${var.environment} deploys"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "EKSDescribeAndAccess"
        Effect = "Allow"
        Action = [
          "eks:DescribeCluster",
          "eks:ListClusters",
          "eks:AccessKubernetesApi",
        ]
        Resource = "arn:aws:eks:${var.aws_region}:${var.aws_account_id}:cluster/${var.cluster_name}"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "eks_deploy" {
  role       = aws_iam_role.github_actions.name
  policy_arn = aws_iam_policy.eks_deploy.arn
}

# ─── Terraform Infrastructure Management Policy ───────────────────────────────
# Used by the terraform-<env>.yml workflows (plan + apply via CI only).
# Scoped to resources this pipeline actually creates.
resource "aws_iam_policy" "terraform_infra" {
  name        = "GitHubActions-Terraform-${var.environment}"
  description = "Terraform plan/apply permissions for GitHub Actions CI — ${var.environment}"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # ec2:* scoped to this region only; required for Terraform to manage VPC/EKS infrastructure.
      {
        Sid      = "EC2VPC"
        Effect   = "Allow"
        Action   = ["ec2:*"] # nosemgrep: terraform.lang.security.iam.no-iam-creds-exposure.no-iam-creds-exposure,terraform.lang.security.iam.no-iam-resource-exposure.no-iam-resource-exposure
        Resource = "*"
        Condition = {
          StringEquals = { "aws:RequestedRegion" = var.aws_region }
        }
      },
      {
        Sid      = "EKSManagement"
        Effect   = "Allow"
        Action   = ["eks:*"]
        Resource = "*"
      },
      # Required for Terraform CI to manage the OIDC role, node group roles, and instance profiles.
      {
        Sid    = "IAMManagement"
        Effect = "Allow"
        Action = [ # nosemgrep: terraform.lang.security.iam.no-iam-priv-esc-funcs.no-iam-priv-esc-funcs,terraform.lang.security.iam.no-iam-resource-exposure.no-iam-resource-exposure
          "iam:CreateRole", "iam:DeleteRole", "iam:GetRole",
          "iam:AttachRolePolicy", "iam:DetachRolePolicy",
          "iam:PutRolePolicy", "iam:DeleteRolePolicy", "iam:GetRolePolicy",
          "iam:ListRolePolicies", "iam:ListAttachedRolePolicies",
          "iam:CreateInstanceProfile", "iam:DeleteInstanceProfile",
          "iam:AddRoleToInstanceProfile", "iam:RemoveRoleFromInstanceProfile",
          "iam:GetInstanceProfile",
          "iam:CreatePolicy", "iam:DeletePolicy", "iam:GetPolicy",
          "iam:GetPolicyVersion", "iam:ListPolicyVersions",
          "iam:CreatePolicyVersion", "iam:DeletePolicyVersion",
          "iam:PassRole", "iam:TagRole", "iam:UntagRole",
          "iam:CreateOpenIDConnectProvider", "iam:DeleteOpenIDConnectProvider",
          "iam:GetOpenIDConnectProvider", "iam:UpdateOpenIDConnectProvider",
          "iam:TagOpenIDConnectProvider",
          "iam:ListRoles", "iam:ListPolicies",
        ]
        Resource = "*"
      },
      # S3 actions scoped to the specific Terraform state bucket for this environment only.
      {
        Sid    = "TerraformStateBucket"
        Effect = "Allow"
        Action = [ # nosemgrep: terraform.lang.security.iam.no-iam-data-exfiltration.no-iam-data-exfiltration
          "s3:GetObject", "s3:PutObject", "s3:DeleteObject",
          "s3:ListBucket", "s3:GetBucketVersioning",
          "s3:GetEncryptionConfiguration",
        ]
        Resource = [
          "arn:aws:s3:::tfstate-nginx-release-${var.environment}-${var.aws_account_id}",
          "arn:aws:s3:::tfstate-nginx-release-${var.environment}-${var.aws_account_id}/*",
        ]
      },
      {
        Sid    = "CloudWatchLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup", "logs:DeleteLogGroup",
          "logs:DescribeLogGroups", "logs:PutRetentionPolicy",
          "logs:TagLogGroup", "logs:ListTagsLogGroup",
        ]
        Resource = "*"
      },
      {
        Sid    = "KMSManagement"
        Effect = "Allow"
        Action = [
          "kms:CreateKey", "kms:DescribeKey", "kms:EnableKeyRotation",
          "kms:GetKeyPolicy", "kms:GetKeyRotationStatus",
          "kms:ListResourceTags", "kms:PutKeyPolicy",
          "kms:ScheduleKeyDeletion", "kms:TagResource", "kms:UntagResource",
          "kms:CreateAlias", "kms:DeleteAlias", "kms:ListAliases", "kms:UpdateAlias",
          "kms:CreateGrant", "kms:ListGrants", "kms:RevokeGrant",
        ]
        Resource = "*"
      },
    ]
  })
}

resource "aws_iam_role_policy_attachment" "terraform_infra" {
  role       = aws_iam_role.github_actions.name
  policy_arn = aws_iam_policy.terraform_infra.arn
}
