output "github_actions_role_arn" {
  value       = aws_iam_role.github_actions.arn
  description = "ARN of the GitHub Actions IAM role — store this in GitHub Actions secrets"
}

output "github_oidc_provider_arn" {
  value       = aws_iam_openid_connect_provider.github.arn
  description = "GitHub OIDC provider ARN"
}
