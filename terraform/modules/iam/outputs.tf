output "eks_cluster_role_arn" {
  description = "EKS cluster IAM role ARN"
  value       = aws_iam_role.eks_cluster.arn
}

output "fargate_pod_execution_role_arn" {
  description = "Fargate pod execution role ARN"
  value       = aws_iam_role.fargate_pod_execution.arn
}

output "account_id" {
  description = "AWS account ID"
  value       = data.aws_caller_identity.current.account_id
}
