resource "aws_iam_role" "karpenter_controller" {
  name = "${var.project_name}-karpenter-controller"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = var.oidc_provider_arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${var.oidc_provider_id}:aud" = "sts.amazonaws.com"
          "${var.oidc_provider_id}:sub" = "system:serviceaccount:kube-system:karpenter"
        }
      }
    }]
  })

  tags = {
    Environment = var.environment
  }
}

resource "aws_iam_role_policy" "karpenter_controller" {
  name = "${var.project_name}-karpenter-controller-policy"
  role = aws_iam_role.karpenter_controller.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "Karpenter"
        Effect = "Allow"
        Action = [
          "ec2:CreateFleet",
          "ec2:CreateLaunchTemplate",
          "ec2:CreateTags",
          "ec2:DeleteLaunchTemplate",
          "ec2:DescribeAvailabilityZones",
          "ec2:DescribeImages",
          "ec2:DescribeInstances",
          "ec2:DescribeInstanceTypeOfferings",
          "ec2:DescribeInstanceTypes",
          "ec2:DescribeLaunchTemplates",
          "ec2:DescribeSecurityGroups",
          "ec2:DescribeSubnets",
          "ec2:RunInstances",
          "ec2:TerminateInstances",
        ]
        Resource = "*"
      },
      {
        Sid      = "PassNodeRole"
        Effect   = "Allow"
        Action   = "iam:PassRole"
        Resource = var.karpenter_node_role_arn
      },
      {
        Sid    = "EKSAccess"
        Effect = "Allow"
        Action = [
          "eks:DescribeCluster",
        ]
        Resource = "arn:aws:eks:${var.aws_region}:${var.account_id}:cluster/${var.cluster_name}"
      },
      {
        Sid    = "SSMGetParameter"
        Effect = "Allow"
        Action = [
          "ssm:GetParameter",
        ]
        Resource = "arn:aws:ssm:${var.aws_region}::parameter/aws/service/*"
      },
      {
        Sid    = "PricingAPI"
        Effect = "Allow"
        Action = [
          "pricing:GetProducts",
        ]
        Resource = "*"
      },
    ]
  })
}
