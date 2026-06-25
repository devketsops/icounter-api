output "eks_cluster_role_arn" {
  description = "EKS cluster IAM role ARN"
  value       = aws_iam_role.eks_cluster.arn
}

output "fargate_pod_execution_role_arn" {
  description = "Fargate pod execution role ARN"
  value       = aws_iam_role.fargate_pod_execution.arn
}

output "karpenter_node_role_arn" {
  description = "Karpenter node IAM role ARN"
  value       = aws_iam_role.karpenter_node.arn
}

output "karpenter_node_role_name" {
  description = "Karpenter node IAM role name"
  value       = aws_iam_role.karpenter_node.name
}

output "karpenter_node_instance_profile_name" {
  description = "Karpenter node instance profile name"
  value       = aws_iam_instance_profile.karpenter_node.name
}

output "account_id" {
  description = "AWS account ID"
  value       = data.aws_caller_identity.current.account_id
}
