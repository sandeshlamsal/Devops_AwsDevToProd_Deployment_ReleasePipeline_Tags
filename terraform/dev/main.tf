terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }

  # Pre-create this S3 bucket before running terraform init (see scripts/bootstrap.sh)
  # Locking uses S3 native conditional writes (Terraform >= 1.10, no DynamoDB needed)
  backend "s3" {
    bucket       = "tfstate-nginx-release-dev-648426766457"
    key          = "eks/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Environment = "dev"
      Project     = "nginx-release"
      ManagedBy   = "terraform"
    }
  }
}

locals {
  environment  = "dev"
  cluster_name = "eks-dev"
}

module "vpc" {
  source = "../modules/vpc"

  environment        = local.environment
  vpc_cidr           = "10.10.0.0/16"
  availability_zones = ["us-east-1a", "us-east-1b"]
  cluster_name       = local.cluster_name

  # IAM policy must be fully applied before VPC resources are created
  # so that KMS and CloudWatch Logs permissions are in effect.
  depends_on = [module.iam_oidc]
}

module "eks" {
  source = "../modules/eks"

  cluster_name       = local.cluster_name
  environment        = local.environment
  public_subnet_ids  = module.vpc.public_subnet_ids
  private_subnet_ids = module.vpc.private_subnet_ids

  # Cost-optimised: small spot instances, min 1 node
  instance_types = ["t3.small", "t3.medium", "t3a.small", "t3a.medium"]
  desired_nodes  = 1
  min_nodes      = 1
  max_nodes      = 3

  # IAM policy must be fully applied before EKS resources are created
  # so that KMS and iam:CreateServiceLinkedRole permissions are in effect.
  depends_on = [module.iam_oidc]
}

# ─── Grant GitHub Actions role kubectl access inside the cluster ──────────────
# EKS access entries API (requires authentication_mode = API_AND_CONFIG_MAP on cluster).
# Scoped to release-app namespace only — least privilege.
resource "aws_eks_access_entry" "github_actions" {
  cluster_name  = module.eks.cluster_name
  principal_arn = module.iam_oidc.github_actions_role_arn
  type          = "STANDARD"

  depends_on = [module.eks, module.iam_oidc]
}

resource "aws_eks_access_policy_association" "github_actions" {
  cluster_name  = module.eks.cluster_name
  principal_arn = module.iam_oidc.github_actions_role_arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }

  depends_on = [aws_eks_access_entry.github_actions]
}

module "iam_oidc" {
  source = "../modules/iam-oidc"

  environment    = local.environment
  aws_region     = var.aws_region
  aws_account_id = var.aws_account_id
  cluster_name   = local.cluster_name
  github_org     = var.github_org
  github_repo    = var.github_repo

  # DEV: main branch (plan job) + named environments (apply/deploy jobs)
  # Jobs that declare `environment:` get subject ..:environment:<name>, NOT ..:ref:..
  allowed_subjects = [
    "repo:${var.github_org}/${var.github_repo}:ref:refs/heads/main",
    "repo:${var.github_org}/${var.github_repo}:environment:dev",
    "repo:${var.github_org}/${var.github_repo}:environment:dev-terraform",
  ]
}
