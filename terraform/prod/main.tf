terraform {
  required_version = ">= 1.6.0"

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

  backend "s3" {
    bucket         = "tfstate-nginx-release-prod-429429082896"
    key            = "eks/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "tfstate-lock-prod"
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Environment = "prod"
      Project     = "nginx-release"
      ManagedBy   = "terraform"
    }
  }
}

locals {
  environment  = "prod"
  cluster_name = "eks-prod"
}

module "vpc" {
  source = "../modules/vpc"

  environment        = local.environment
  vpc_cidr           = "10.30.0.0/16"
  availability_zones = ["us-east-1a", "us-east-1b"]
  cluster_name       = local.cluster_name
}

module "eks" {
  source = "../modules/eks"

  cluster_name       = local.cluster_name
  environment        = local.environment
  public_subnet_ids  = module.vpc.public_subnet_ids
  private_subnet_ids = module.vpc.private_subnet_ids

  # Prod: slightly larger pool, still spot for cost — add on-demand if needed
  instance_types = ["t3.medium", "t3.large", "t3a.medium", "t3a.large"]
  desired_nodes  = 2
  min_nodes      = 2
  max_nodes      = 5
}

module "iam_oidc" {
  source = "../modules/iam-oidc"

  environment    = local.environment
  aws_region     = var.aws_region
  aws_account_id = var.aws_account_id
  cluster_name   = local.cluster_name
  github_org     = var.github_org
  github_repo    = var.github_repo

  # PROD: tags for k8s deploys + main branch for terraform plan/apply via CI
  # The 'prod' GitHub Environment gate (required reviewers) is what enforces
  # human approval before any terraform apply runs against this account.
  allowed_subjects = [
    "repo:${var.github_org}/${var.github_repo}:ref:refs/tags/prod_*",
    "repo:${var.github_org}/${var.github_repo}:ref:refs/heads/main",
  ]
}
