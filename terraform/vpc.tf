# ── VPC ──────────────────────────────────────────────────────
# Uses the official AWS VPC module (terraform-aws-modules/vpc/aws).
# Creates: VPC, 3 private subnets (nodes), 3 public subnets (ALBs),
#          Internet Gateway, NAT Gateway, and route tables.

module "vpc" {
  source  = "registry.terraform.io/terraform-aws-modules/vpc/aws"
  version = "~> 5.5"

  name = "${var.cluster_name}-vpc"
  cidr = var.vpc_cidr

  azs             = var.availability_zones
  private_subnets = var.private_subnet_cidrs
  public_subnets  = var.public_subnet_cidrs

  # NAT Gateway — one per VPC (single AZ NAT is enough for dev; saves cost)
  enable_nat_gateway     = true
  single_nat_gateway     = true
  one_nat_gateway_per_az = false

  # DNS — required by EKS
  enable_dns_hostnames = true
  enable_dns_support   = true

  # Subnet tags required by ALB Controller and EKS to discover subnets
  public_subnet_tags = {
    "kubernetes.io/role/elb"                        = "1"
    "kubernetes.io/cluster/${var.cluster_name}"     = "shared"
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb"               = "1"
    "kubernetes.io/cluster/${var.cluster_name}"     = "shared"
  }
}
