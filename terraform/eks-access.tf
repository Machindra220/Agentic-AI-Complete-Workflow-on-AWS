# ── EKS Console Access ───────────────────────────────────────
# Grants your IAM user full visibility of K8s resources
# in the AWS Console (EKS → Cluster → Resources tab).
#
# Root user CANNOT be added to EKS — AWS does not support it.
# Use IAM user "Machindra" to log into the console instead.

locals {
  admin_iam_user_arn = "arn:aws:iam::${var.aws_account_id}:user/Machindra"
}

# Access entry — registers the IAM user with the cluster
resource "aws_eks_access_entry" "admin" {
  cluster_name  = module.eks.cluster_name
  principal_arn = local.admin_iam_user_arn
  type          = "STANDARD"

  depends_on = [module.eks]
}

# Policy association — grants cluster-admin level access
resource "aws_eks_access_policy_association" "admin" {
  cluster_name  = module.eks.cluster_name
  principal_arn = local.admin_iam_user_arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"  # full cluster scope (all namespaces)
  }

  depends_on = [aws_eks_access_entry.admin]
}
