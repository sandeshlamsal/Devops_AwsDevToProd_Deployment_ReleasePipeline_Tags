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

  # Locking uses S3 native conditional writes (Terraform >= 1.10, no DynamoDB needed)
  backend "s3" {
    bucket       = "tfstate-nginx-release-qa-506250256146"
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
      Environment = "qa"
      Project     = "nginx-release"
      ManagedBy   = "terraform"
    }
  }
}

locals {
  environment  = "qa"
  cluster_name = "eks-qa"
}

module "vpc" {
  source = "../modules/vpc"

  environment        = local.environment
  vpc_cidr           = "10.20.0.0/16"
  availability_zones = ["us-east-1a", "us-east-1b"]
  cluster_name       = local.cluster_name
}

module "eks" {
  source = "../modules/eks"

  cluster_name       = local.cluster_name
  environment        = local.environment
  public_subnet_ids  = module.vpc.public_subnet_ids
  private_subnet_ids = module.vpc.private_subnet_ids

  instance_types = ["t3.small", "t3.medium", "t3a.small", "t3a.medium"]
  desired_nodes  = 1
  min_nodes      = 1
  max_nodes      = 3
}

module "iam_oidc" {
  source = "../modules/iam-oidc"

  environment    = local.environment
  aws_region     = var.aws_region
  aws_account_id = var.aws_account_id
  cluster_name   = local.cluster_name
  github_org     = var.github_org
  github_repo    = var.github_repo

  # QA: tags for k8s deploys + main branch for terraform plan/apply via CI
  allowed_subjects = [
    "repo:${var.github_org}/${var.github_repo}:ref:refs/tags/qa_*",
    "repo:${var.github_org}/${var.github_repo}:ref:refs/heads/main",
  ]
}
