variable "cluster_name" {
  type        = string
  description = "EKS cluster name"
}

variable "environment" {
  type        = string
  description = "Environment (dev, qa, prod)"
}

variable "kubernetes_version" {
  type        = string
  description = "EKS Kubernetes version"
  default     = "1.34"
}

variable "public_subnet_ids" {
  type        = list(string)
  description = "Public subnet IDs (for control plane ENIs)"
}

variable "private_subnet_ids" {
  type        = list(string)
  description = "Private subnet IDs (nodes deployed here)"
}

variable "public_access_cidrs" {
  type        = list(string)
  description = "CIDRs allowed to reach the public API endpoint"
  default     = ["0.0.0.0/0"]
}

variable "instance_types" {
  type        = list(string)
  description = "List of instance types for the spot node group"
  default     = ["t3.small", "t3.medium", "t3a.small", "t3a.medium"]
}

variable "desired_nodes" {
  type        = number
  description = "Desired number of nodes"
  default     = 1
}

variable "min_nodes" {
  type        = number
  description = "Minimum number of nodes"
  default     = 1
}

variable "max_nodes" {
  type        = number
  description = "Maximum number of nodes"
  default     = 3
}

variable "tags" {
  type        = map(string)
  description = "Common resource tags"
  default     = {}
}
