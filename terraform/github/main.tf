terraform {
  required_version = ">= 1.10.0"

  required_providers {
    github = {
      source  = "integrations/github"
      version = "~> 6.0"
    }
  }

  # Reuse the DEV account S3 bucket with a separate state key
  # Locking uses S3 native conditional writes (Terraform >= 1.10, no DynamoDB needed)
  backend "s3" {
    bucket       = "tfstate-nginx-release-dev-648426766457"
    key          = "github-environments/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}

# Token comes from GITHUB_TOKEN env var set in the workflow (GH_PAT secret)
provider "github" {
  owner = var.github_org
}

# ─── Resolve all reviewer usernames → numeric IDs ─────────────────────────────
data "github_user" "reviewer" {
  for_each = toset(local.all_reviewer_usernames)
  username = each.key
}

locals {
  # Flat union of every reviewer list — used for the data source loop
  all_reviewer_usernames = toset(concat(
    var.dev_app_reviewers,
    var.prod_app_reviewers,
    var.dev_terraform_reviewers,
    var.qa_terraform_reviewers,
    var.prod_terraform_reviewers,
  ))

  # Map username → numeric GitHub user ID
  uid = { for u in local.all_reviewer_usernames : u => data.github_user.reviewer[u].id }
}

# ── App deploy environments ───────────────────────────────────────────────────

resource "github_repository_environment" "dev" {
  repository  = var.github_repo
  environment = "dev"

  # Optional gate — empty list = auto-deploy, add names to gate like PROD
  dynamic "reviewers" {
    for_each = length(var.dev_app_reviewers) > 0 ? [1] : []
    content {
      users = [for u in var.dev_app_reviewers : local.uid[u]]
    }
  }
}

resource "github_repository_environment" "qa" {
  repository  = var.github_repo
  environment = "qa"
  # No reviewers — promotion is gated by the qa_* tag requirement in the pipeline
}

resource "github_repository_environment" "prod" {
  repository          = var.github_repo
  environment         = "prod"
  prevent_self_review = true
  wait_timer          = var.prod_wait_minutes # optional delay after approval

  reviewers {
    users = [for u in var.prod_app_reviewers : local.uid[u]]
  }
}

# ── Terraform environments ────────────────────────────────────────────────────

resource "github_repository_environment" "dev_terraform" {
  repository  = var.github_repo
  environment = "dev-terraform"

  # Optional gate — leave var.dev_terraform_reviewers empty for auto-apply
  dynamic "reviewers" {
    for_each = length(var.dev_terraform_reviewers) > 0 ? [1] : []
    content {
      users = [for u in var.dev_terraform_reviewers : local.uid[u]]
    }
  }
}

resource "github_repository_environment" "qa_terraform" {
  repository          = var.github_repo
  environment         = "qa-terraform"
  prevent_self_review = true

  reviewers {
    users = [for u in var.qa_terraform_reviewers : local.uid[u]]
  }
}

resource "github_repository_environment" "prod_terraform" {
  repository          = var.github_repo
  environment         = "prod-terraform"
  prevent_self_review = true
  wait_timer          = var.prod_wait_minutes

  reviewers {
    users = [for u in var.prod_terraform_reviewers : local.uid[u]]
  }
}
