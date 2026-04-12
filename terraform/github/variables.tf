variable "github_org" {
  type        = string
  description = "GitHub organisation or username"
}

variable "github_repo" {
  type        = string
  description = "GitHub repository name (without the org prefix)"
}

# ── Reviewer lists — GitHub usernames, not emails ─────────────────────────────

variable "dev_app_reviewers" {
  type        = list(string)
  description = "GitHub usernames that must approve DEV app deployments. Empty = auto-deploy."
  default     = []
}

variable "prod_app_reviewers" {
  type        = list(string)
  description = "GitHub usernames that must approve PROD app deployments (deploy-prod.yml)"
}

variable "dev_terraform_reviewers" {
  type        = list(string)
  description = "GitHub usernames that must approve DEV terraform apply. Empty = no gate."
  default     = []
}

variable "qa_terraform_reviewers" {
  type        = list(string)
  description = "GitHub usernames that must approve QA terraform apply"
}

variable "prod_terraform_reviewers" {
  type        = list(string)
  description = "GitHub usernames that must approve PROD terraform apply"
}

variable "prod_wait_minutes" {
  type        = number
  description = "Minutes to wait after approval before PROD jobs start (0 = immediate)"
  default     = 0
}
