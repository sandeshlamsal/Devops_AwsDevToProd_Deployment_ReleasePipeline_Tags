output "cluster_name" {
  value = module.eks.cluster_name
}

output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "github_actions_role_arn" {
  value       = module.iam_oidc.github_actions_role_arn
  description = "Set this as DEV_IAM_ROLE_ARN in GitHub Actions secrets"
}
