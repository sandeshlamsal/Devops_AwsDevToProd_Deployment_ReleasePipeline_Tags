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

# ─── EKS Deploy Policy ────────────────────────────────────────────────────────
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
