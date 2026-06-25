locals {
  cluster_name = "${var.project_name}-cluster"
}

module "vpc" {
  source = "./modules/vpc"

  project_name = var.project_name
  environment  = var.environment
  vpc_cidr     = var.vpc_cidr
  aws_region   = var.aws_region
  cluster_name = local.cluster_name
}

module "iam" {
  source = "./modules/iam"

  project_name = var.project_name
  environment  = var.environment
}

module "eks" {
  source = "./modules/eks"

  project_name                  = var.project_name
  environment                   = var.environment
  cluster_version               = var.eks_cluster_version
  cluster_role_arn              = module.iam.eks_cluster_role_arn
  fargate_pod_execution_role_arn = module.iam.fargate_pod_execution_role_arn
  karpenter_node_role_arn       = module.iam.karpenter_node_role_arn
  private_subnet_ids            = module.vpc.private_subnet_ids
  public_subnet_ids             = module.vpc.public_subnet_ids
  vpc_id                        = module.vpc.vpc_id

  depends_on = [module.iam]
}

module "ecr" {
  source = "./modules/ecr"

  project_name = var.project_name
  environment  = var.environment
}

module "karpenter" {
  source = "./modules/karpenter"

  project_name                    = var.project_name
  environment                     = var.environment
  cluster_name                    = module.eks.cluster_name
  cluster_endpoint                = module.eks.cluster_endpoint
  oidc_provider_arn               = module.eks.oidc_provider_arn
  oidc_provider_id                = module.eks.oidc_provider_id
  karpenter_node_role_arn         = module.iam.karpenter_node_role_arn
  karpenter_node_role_name        = module.iam.karpenter_node_role_name
  karpenter_instance_profile_name = module.iam.karpenter_node_instance_profile_name
  cluster_security_group_id       = module.eks.cluster_security_group_id
  aws_region                      = var.aws_region
  account_id                      = module.iam.account_id

  depends_on = [module.eks]
}

module "alb_controller" {
  source = "./modules/alb-controller"

  project_name      = var.project_name
  environment       = var.environment
  cluster_name      = module.eks.cluster_name
  oidc_provider_arn = module.eks.oidc_provider_arn
  oidc_provider_id  = module.eks.oidc_provider_id
  vpc_id            = module.vpc.vpc_id
  aws_region        = var.aws_region

  depends_on = [module.eks]
}
