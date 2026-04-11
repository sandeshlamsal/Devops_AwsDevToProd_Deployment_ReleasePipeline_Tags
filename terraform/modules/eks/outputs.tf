output "cluster_name" {
  value       = aws_eks_cluster.main.name
  description = "EKS cluster name"
}

output "cluster_endpoint" {
  value       = aws_eks_cluster.main.endpoint
  description = "EKS API server endpoint"
}

output "cluster_certificate_authority_data" {
  value       = aws_eks_cluster.main.certificate_authority[0].data
  description = "Base64-encoded cluster CA certificate"
}

output "cluster_oidc_issuer_url" {
  value       = aws_eks_cluster.main.identity[0].oidc[0].issuer
  description = "OIDC issuer URL for IRSA"
}

output "eks_oidc_provider_arn" {
  value       = aws_iam_openid_connect_provider.eks.arn
  description = "EKS OIDC provider ARN (for IRSA)"
}

output "node_group_role_arn" {
  value       = aws_iam_role.node_group.arn
  description = "Node group IAM role ARN"
}
