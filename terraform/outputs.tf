output "eks_cluster_endpoint" {
  description = "EKS cluster endpoint"
  value       = module.eks.cluster_endpoint
}

output "eks_cluster_name" {
  description = "EKS cluster name"
  value       = module.eks.cluster_name
}

output "ecr_repository_url" {
  description = "ECR repository URL"
  value       = module.ecr.repository_url
}

output "vpc_id" {
  description = "VPC ID"
  value       = module.vpc.vpc_id
}

output "alb_controller_role_arn" {
  description = "ALB controller IAM role ARN (pass to Helm install)"
  value       = module.alb_controller.alb_controller_role_arn
}

output "karpenter_controller_role_arn" {
  description = "Karpenter controller IAM role ARN (pass to Helm install)"
  value       = module.karpenter_iam.karpenter_controller_role_arn
}

output "kubeconfig_command" {
  description = "Command to configure kubectl"
  value       = "aws eks update-kubeconfig --name ${module.eks.cluster_name} --region ${var.aws_region}"
}
