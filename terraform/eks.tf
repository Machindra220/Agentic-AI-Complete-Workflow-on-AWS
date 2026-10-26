# ── EKS Cluster ──────────────────────────────────────────────
# Uses the official AWS EKS module (terraform-aws-modules/eks/aws).
# Creates: EKS control plane, OIDC provider, 2 managed node groups,
#          and aws-auth ConfigMap entries.

module "eks" {
  source  = "registry.terraform.io/terraform-aws-modules/eks/aws"
  version = "~> 20.8"

  cluster_name    = var.cluster_name
  cluster_version = var.kubernetes_version

  # VPC — nodes in private subnets
  vpc_id                   = module.vpc.vpc_id
  subnet_ids               = module.vpc.private_subnets
  control_plane_subnet_ids = module.vpc.private_subnets

  # API server — accessible from public internet (restrict via security group below)
  # and from inside the VPC.
  cluster_endpoint_public_access  = true
  cluster_endpoint_private_access = true

  # OIDC provider — required for IRSA (no static AWS keys in pods)
  enable_irsa = true

  # EKS Add-ons (managed, auto-updated patch versions)
  cluster_addons = {
    coredns = {
      most_recent = true
    }
    kube-proxy = {
      most_recent = true
    }
    vpc-cni = {
      most_recent = true
    }
    aws-ebs-csi-driver = {
      most_recent              = true
      service_account_role_arn = aws_iam_role.ebs_csi.arn
    }
  }

  # ── Node Groups ─────────────────────────────────────────────
  eks_managed_node_groups = {

    # app-nodes: FastAPI, pgvector, Prometheus, Grafana, chaoskube
    app_nodes = {
      name           = "app-nodes"
      instance_types = [var.app_node_instance_type]

      min_size     = var.app_node_min
      max_size     = var.app_node_max
      desired_size = var.app_node_desired

      # Nodes in private subnets — no public IPs
      subnet_ids = module.vpc.private_subnets

      labels = {
        workload = "app"
      }

      # Disk: 20GB gp3 (better perf than gp2, same price)
      block_device_mappings = {
        xvda = {
          device_name = "/dev/xvda"
          ebs = {
            volume_size           = 20
            volume_type           = "gp3"
            encrypted             = true
            delete_on_termination = true
          }
        }
      }
    }

    # agent-nodes: LangGraph AI agent (tainted so only agent pod lands here)
    agent_nodes = {
      name           = "agent-nodes"
      instance_types = [var.agent_node_instance_type]

      min_size     = var.agent_node_min
      max_size     = var.agent_node_max
      desired_size = var.agent_node_desired

      subnet_ids = module.vpc.private_subnets

      labels = {
        workload = "ai-agent"
      }

      # Taint: only pods with toleration workload=ai-agent land here
      taints = {
        ai_agent = {
          key    = "workload"
          value  = "ai-agent"
          effect = "NO_SCHEDULE"
        }
      }

      block_device_mappings = {
        xvda = {
          device_name = "/dev/xvda"
          ebs = {
            volume_size           = 20
            volume_type           = "gp3"
            encrypted             = true
            delete_on_termination = true
          }
        }
      }
    }
  }

  # Grant cluster-admin to the IAM user/role running Terraform
  enable_cluster_creator_admin_permissions = true
}

# ── EBS CSI Driver IRSA ──────────────────────────────────────
# Required for pgvector PVC (EBS volume)
data "aws_iam_policy_document" "ebs_csi_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"

    principals {
      type        = "Federated"
      identifiers = [module.eks.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${module.eks.oidc_provider}:sub"
      values   = ["system:serviceaccount:kube-system:ebs-csi-controller-sa"]
    }

    condition {
      test     = "StringEquals"
      variable = "${module.eks.oidc_provider}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ebs_csi" {
  name               = "${var.cluster_name}-ebs-csi-role"
  assume_role_policy = data.aws_iam_policy_document.ebs_csi_assume.json
}

resource "aws_iam_role_policy_attachment" "ebs_csi" {
  role       = aws_iam_role.ebs_csi.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}
