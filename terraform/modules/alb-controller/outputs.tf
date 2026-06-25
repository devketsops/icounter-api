output "alb_controller_role_arn" {
  description = "ALB controller IAM role ARN"
  value       = aws_iam_role.alb_controller.arn
}
