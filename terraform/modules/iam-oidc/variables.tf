variable "environment" {
  type        = string
  description = "Environment name (dev, qa, prod)"
}

variable "aws_region" {
  type        = string
  description = "AWS region"
  default     = "us-east-1"
}

variable "aws_account_id" {
  type        = string
  description = "AWS account ID where this role will be created"
}

variable "cluster_name" {
  type        = string
  description = "EKS cluster name this role can access"
}

variable "github_org" {
  type        = string
  description = "GitHub organisation or username (e.g. myorg)"
}

variable "github_repo" {
  type        = string
  description = "GitHub repository name (e.g. my-app)"
}

variable "allowed_subjects" {
  type        = list(string)
  description = <<-EOT
    OIDC subject conditions that can assume this role.
    Examples:
      dev  → ["repo:org/repo:ref:refs/heads/main"]
      qa   → ["repo:org/repo:ref:refs/tags/qa_*"]
      prod → ["repo:org/repo:ref:refs/tags/prod_*"]
  EOT
}

variable "tags" {
  type        = map(string)
  description = "Common resource tags"
  default     = {}
}
