output "karpenter_controller_role_arn" {
  description = "Karpenter controller IAM role ARN"
  value       = aws_iam_role.karpenter_controller.arn
}

output "interruption_queue_name" {
  description = "SQS queue name for spot interruption handling"
  value       = aws_sqs_queue.karpenter_interruption.name
}
