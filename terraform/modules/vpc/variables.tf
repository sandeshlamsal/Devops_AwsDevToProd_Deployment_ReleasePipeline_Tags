variable "environment" {
  type        = string
  description = "Environment name (dev, qa, prod)"
}

variable "vpc_cidr" {
  type        = string
  description = "VPC CIDR block"
  default     = "10.0.0.0/16"
}

variable "availability_zones" {
  type        = list(string)
  description = "List of AZs to use (2 minimum)"
}

variable "cluster_name" {
  type        = string
  description = "EKS cluster name — used for subnet tagging"
}

variable "tags" {
  type        = map(string)
  description = "Common tags to apply to all resources"
  default     = {}
}
