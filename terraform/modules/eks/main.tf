locals {
  cluster_name = "${var.project_name}-cluster"
}

resource "aws_eks_cluster" "main" {
  name     = local.cluster_name
  version  = var.cluster_version
  role_arn = var.cluster_role_arn

  vpc_config {
    subnet_ids              = concat(var.private_subnet_ids, var.public_subnet_ids)
    endpoint_private_access = true
    endpoint_public_access  = true
  }

  access_config {
    authentication_mode = "API_AND_CONFIG_MAP"
  }

  tags = {
    Name        = local.cluster_name
    Environment = var.environment
  }
}

# Allow Karpenter nodes to join the cluster
resource "aws_eks_access_entry" "karpenter_node" {
  cluster_name  = aws_eks_cluster.main.name
  principal_arn = var.karpenter_node_role_arn
  type          = "EC2_LINUX"
}

# Fargate profile for system components (kube-system namespace)
resource "aws_eks_fargate_profile" "kube_system" {
  cluster_name           = aws_eks_cluster.main.name
  fargate_profile_name   = "${var.project_name}-kube-system"
  pod_execution_role_arn = var.fargate_pod_execution_role_arn
  subnet_ids             = var.private_subnet_ids

  selector {
    namespace = "kube-system"
  }

  tags = {
    Environment = var.environment
  }
}

# EKS Add-ons
resource "aws_eks_addon" "vpc_cni" {
  cluster_name = aws_eks_cluster.main.name
  addon_name   = "vpc-cni"

  depends_on = [aws_eks_fargate_profile.kube_system]
}

resource "aws_eks_addon" "kube_proxy" {
  cluster_name = aws_eks_cluster.main.name
  addon_name   = "kube-proxy"

  depends_on = [aws_eks_fargate_profile.kube_system]
}

resource "aws_eks_addon" "coredns" {
  cluster_name = aws_eks_cluster.main.name
  addon_name   = "coredns"

  configuration_values = jsonencode({
    computeType = "Fargate"
  })

  depends_on = [aws_eks_fargate_profile.kube_system]
}

# OIDC provider for IRSA
data "tls_certificate" "eks" {
  url = aws_eks_cluster.main.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "eks" {
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks.certificates[0].sha1_fingerprint]
  url             = aws_eks_cluster.main.identity[0].oidc[0].issuer

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
