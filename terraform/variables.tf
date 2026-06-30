variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "ap-south-1"
}

variable "project_name" {
  description = "Project name used for resource naming"
  type        = string
  default     = "icounter"
}

variable "environment" {
  description = "Environment name"
  type        = string
  default     = "staging"
}

variable "vpc_cidr" {
  description = "VPC CIDR block"
  type        = string
  default     = "10.0.0.0/16"
}

variable "eks_cluster_version" {
  description = "EKS cluster Kubernetes version"
  type        = string
  default     = "1.35"
}

variable "eks_public_access_cidrs" {
  description = "CIDR blocks allowed to access the EKS public API endpoint"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "ecr_force_delete" {
  description = "Allow force-deleting the ECR repository even if it contains images. Set to false for production."
  type        = bool
  default     = false
}

variable "db_password" {
  description = "Database password stored in AWS Secrets Manager"
  type        = string
  sensitive   = true
  default     = "change-me"
}

variable "api_key" {
  description = "API key stored in AWS Secrets Manager"
  type        = string
  sensitive   = true
  default     = "change-me"
}

variable "core_node_instance_types" {
  description = "Instance types for the core infrastructure managed node group"
  type        = list(string)
  default     = ["t3.medium"]
}

variable "core_node_desired_size" {
  description = "Desired number of core infrastructure nodes"
  type        = number
  default     = 2
}

variable "core_node_min_size" {
  description = "Minimum number of core infrastructure nodes"
  type        = number
  default     = 2
}

variable "core_node_max_size" {
  description = "Maximum number of core infrastructure nodes"
  type        = number
  default     = 3
}

