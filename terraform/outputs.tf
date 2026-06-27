output "eks_cluster_endpoint" {
  description = "EKS cluster endpoint"
  value       = aws_eks_cluster.main.endpoint
}

output "eks_cluster_name" {
  description = "EKS cluster name"
  value       = aws_eks_cluster.main.name
}

output "ecr_repository_url" {
  description = "ECR repository URL"
  value       = aws_ecr_repository.main.repository_url
}

output "vpc_id" {
  description = "VPC ID"
  value       = aws_vpc.main.id
}

output "alb_controller_role_arn" {
  description = "ALB controller IAM role ARN (pass to Helm install)"
  value       = aws_iam_role.alb_controller.arn
}

output "karpenter_controller_role_arn" {
  description = "Karpenter controller IAM role ARN (pass to Helm install)"
  value       = aws_iam_role.karpenter_controller.arn
}

output "core_node_role_arn" {
  description = "Core infrastructure node group IAM role ARN"
  value       = aws_iam_role.core_node.arn
}

output "kubeconfig_command" {
  description = "Command to configure kubectl"
  value       = "aws eks update-kubeconfig --name ${aws_eks_cluster.main.name} --region ${var.aws_region}"
}
