output "karpenter_controller_role_arn" {
  description = "Karpenter controller IAM role ARN (for IRSA)"
  value       = aws_iam_role.karpenter_controller.arn
}
