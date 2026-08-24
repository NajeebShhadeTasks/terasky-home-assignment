data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_caller_identity" "current" {}

locals {
  # Two AZs: minimum for high availability, cost-conscious for a demo.
  azs = slice(data.aws_availability_zones.available.names, 0, 2)

  private_subnets = [for i, az in local.azs : cidrsubnet(var.vpc_cidr, 4, i)]
  public_subnets  = [for i, az in local.azs : cidrsubnet(var.vpc_cidr, 4, i + 8)]
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.21"

  name = "${var.project_name}-vpc"
  cidr = var.vpc_cidr

  azs             = local.azs
  private_subnets = local.private_subnets
  public_subnets  = local.public_subnets

  # DEMO cost optimization: a single NAT gateway (~32 USD/month + data) instead
  # of one per AZ. In production use one NAT per AZ (see docs/aws-production-design.md)
  # or VPC endpoints for ECR/S3/STS to remove most NAT traffic entirely.
  enable_nat_gateway = true
  single_nat_gateway = true

  enable_dns_hostnames = true
  enable_dns_support   = true

  # Subnet discovery tags for (a future) AWS Load Balancer Controller.
  public_subnet_tags = {
    "kubernetes.io/role/elb" = "1"
  }
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = "1"
  }
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.37"

  cluster_name    = var.project_name
  cluster_version = var.cluster_version

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  # DEMO trade-off: public API endpoint so the assignment can be driven from a
  # laptop without a bastion/VPN. Production: private endpoint (documented).
  cluster_endpoint_public_access = true

  # Modern access-entry based auth (no aws-auth ConfigMap).
  authentication_mode                      = "API"
  enable_cluster_creator_admin_permissions = true

  # Control plane logging: API + audit + authenticator to CloudWatch.
  cluster_enabled_log_types = ["api", "audit", "authenticator"]

  # IRSA (IAM Roles for Service Accounts) - used by External Secrets Operator.
  enable_irsa = true

  cluster_addons = {
    coredns    = {}
    kube-proxy = {}
    vpc-cni = {
      before_compute = true
      # Enable the VPC CNI NetworkPolicy agent so Kubernetes NetworkPolicy
      # objects are actually enforced on this cluster.
      configuration_values = jsonencode({
        enableNetworkPolicy = "true"
      })
    }
  }

  eks_managed_node_groups = {
    default = {
      name           = "${var.project_name}-ng"
      ami_type       = "AL2023_x86_64_STANDARD"
      instance_types = var.node_instance_types
      capacity_type  = "ON_DEMAND"

      min_size     = var.node_group_min_size
      max_size     = var.node_group_max_size
      desired_size = var.node_group_desired_size
    }
  }

  tags = {
    Name = var.project_name
  }
}
