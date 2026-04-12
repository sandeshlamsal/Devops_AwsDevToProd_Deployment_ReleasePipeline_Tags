output "environments" {
  description = "All configured GitHub environments and their reviewer counts"
  value = {
    dev            = { reviewers = 0 }
    qa             = { reviewers = 0 }
    prod           = { reviewers = length(var.prod_app_reviewers) }
    dev_terraform  = { reviewers = length(var.dev_terraform_reviewers) }
    qa_terraform   = { reviewers = length(var.qa_terraform_reviewers) }
    prod_terraform = { reviewers = length(var.prod_terraform_reviewers) }
  }
}
