resource "aws_eks_cluster" "main" {
  name     = local.cluster_name
  version  = var.eks_cluster_version
  role_arn = aws_iam_role.eks_cluster.arn

  vpc_config {
    subnet_ids              = concat(aws_subnet.private[*].id, aws_subnet.public[*].id)
    endpoint_private_access = true
    endpoint_public_access  = true
  }

  access_config {
    authentication_mode = "API"
  }

  tags = {
    Name        = local.cluster_name
    Environment = var.environment
  }
}

# Allow Karpenter nodes to join the cluster
resource "aws_eks_access_entry" "karpenter_node" {
  cluster_name  = aws_eks_cluster.main.name
  principal_arn = aws_iam_role.karpenter_node.arn
  type          = "EC2_LINUX"
}

# Grant cluster admin access to the IAM identity running Terraform
resource "aws_eks_access_entry" "admin" {
  cluster_name  = aws_eks_cluster.main.name
  principal_arn = data.aws_caller_identity.current.arn
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "admin" {
  cluster_name  = aws_eks_cluster.main.name
  principal_arn = data.aws_caller_identity.current.arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }
}

# Allow core managed node group nodes to join the cluster
resource "aws_eks_access_entry" "core_node" {
  cluster_name  = aws_eks_cluster.main.name
  principal_arn = aws_iam_role.core_node.arn
  type          = "EC2_LINUX"
}

# Core infrastructure managed node group
resource "aws_eks_node_group" "core" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "${var.project_name}-core-infra"
  node_role_arn   = aws_iam_role.core_node.arn
  subnet_ids      = aws_subnet.private[*].id

  instance_types = var.core_node_instance_types

  scaling_config {
    desired_size = var.core_node_desired_size
    min_size     = var.core_node_min_size
    max_size     = var.core_node_max_size
  }

  taint {
    key    = "CriticalAddonsOnly"
    value  = "true"
    effect = "NO_SCHEDULE"
  }

  labels = {
    "node-role" = "core-infra"
  }

  update_config {
    max_unavailable = 1
  }

  tags = {
    Name        = "${var.project_name}-core-infra"
    Environment = var.environment
  }

  depends_on = [
    aws_iam_role_policy_attachment.core_node_worker,
    aws_iam_role_policy_attachment.core_node_cni,
    aws_iam_role_policy_attachment.core_node_ecr,
    aws_iam_role_policy_attachment.core_node_ssm,
  ]
}

# EKS Add-ons
resource "aws_eks_addon" "vpc_cni" {
  cluster_name = aws_eks_cluster.main.name
  addon_name   = "vpc-cni"

  depends_on = [aws_eks_node_group.core]
}

resource "aws_eks_addon" "kube_proxy" {
  cluster_name = aws_eks_cluster.main.name
  addon_name   = "kube-proxy"

  depends_on = [aws_eks_node_group.core]
}

resource "aws_eks_addon" "coredns" {
  cluster_name = aws_eks_cluster.main.name
  addon_name   = "coredns"

  configuration_values = jsonencode({
    tolerations = [{
      key      = "CriticalAddonsOnly"
      operator = "Exists"
      effect   = "NoSchedule"
    }]
    nodeSelector = {
      "node-role" = "core-infra"
    }
  })

  depends_on = [aws_eks_node_group.core]
}

# OIDC provider for IRSA
resource "aws_iam_openid_connect_provider" "eks" {
  client_id_list = ["sts.amazonaws.com"]
  url            = aws_eks_cluster.main.identity[0].oidc[0].issuer

  tags = {
    Name        = "${var.project_name}-eks-oidc"
    Environment = var.environment
  }
}

# Tag cluster security group for Karpenter discovery
resource "aws_ec2_tag" "cluster_sg_karpenter" {
  resource_id = aws_eks_cluster.main.vpc_config[0].cluster_security_group_id
  key         = "karpenter.sh/discovery"
  value       = local.cluster_name
}
