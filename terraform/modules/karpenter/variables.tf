variable "project_name" {
  description = "Project name for resource naming"
  type        = string
}

variable "environment" {
  description = "Environment name"
  type        = string
}

variable "cluster_name" {
  description = "EKS cluster name"
  type        = string
}

variable "cluster_endpoint" {
  description = "EKS cluster endpoint"
  type        = string
}

variable "oidc_provider_arn" {
  description = "OIDC provider ARN"
  type        = string
}

variable "oidc_provider_id" {
  description = "OIDC provider ID"
  type        = string
}

variable "karpenter_node_role_arn" {
  description = "Karpenter node IAM role ARN"
  type        = string
}

variable "karpenter_node_role_name" {
  description = "Karpenter node IAM role name"
  type        = string
}

variable "karpenter_instance_profile_name" {
  description = "Karpenter node instance profile name"
  type        = string
}

variable "cluster_security_group_id" {
  description = "EKS cluster security group ID"
  type        = string
}

variable "aws_region" {
  description = "AWS region"
  type        = string
}

variable "account_id" {
  description = "AWS account ID"
  type        = string
}
