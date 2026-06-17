variable "region" {
  description = "AWS region to deploy into"
  type        = string
  default     = "us-east-1"
}

variable "project" {
  description = "Tag applied to all resources. The start and stop scripts filter on it."
  type        = string
  default     = "teleport"
}

variable "my_ip_cidr" {
  description = "Your public IP in CIDR form. Locks down SSH and the API server. Example 203.0.113.10/32"
  type        = string
}

variable "cp_instance_type" {
  description = "Instance type for the control plane. Needs at least 2 vCPU and 2 GB."
  type        = string
  default     = "t3.medium"
}

variable "worker_instance_type" {
  description = "Instance type for the workers"
  type        = string
  default     = "t3.small"
}

variable "root_volume_gb" {
  description = "Root EBS volume size in GB for each node"
  type        = number
  default     = 20
}
