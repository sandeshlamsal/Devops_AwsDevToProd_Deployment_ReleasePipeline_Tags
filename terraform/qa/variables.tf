variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "aws_account_id" {
  type    = string
  default = "506250256146"
}

variable "github_org" {
  type        = string
  description = "GitHub org or username"
}

variable "github_repo" {
  type        = string
  description = "GitHub repository name"
}
