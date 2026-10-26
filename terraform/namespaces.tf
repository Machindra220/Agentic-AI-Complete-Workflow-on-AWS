# ── Kubernetes Namespaces ─────────────────────────────────────
# Created via Terraform so they exist before Helm charts deploy.
# depends_on ensures the cluster is fully up before kubectl calls.

resource "kubernetes_namespace" "namespaces" {
  for_each = toset(["sre-ai-agent", "sre-ai-agent-llm", "monitoring", "chaos"])

  metadata {
    name = each.key
    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
      "project"                      = "sre-ai-agent"
    }
  }

  depends_on = [module.eks]
}

# ── ALB Controller (Helm) ─────────────────────────────────────
# Installed here so it is ready before any LoadBalancer services
# in later phases (deploy-app, deploy-agent) are created.

resource "helm_release" "alb_controller" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  namespace  = "kube-system"
  version    = "1.7.2"

  set {
    name  = "clusterName"
    value = module.eks.cluster_name
  }

  set {
    name  = "serviceAccount.create"
    value = "true"
  }

  set {
    name  = "serviceAccount.name"
    value = "aws-load-balancer-controller"
  }

  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = aws_iam_role.alb_controller.arn
  }

  # Security: disable default webhook cert (use cert-manager if needed later)
  set {
    name  = "enableCertManager"
    value = "false"
  }

  depends_on = [
    module.eks,
    aws_iam_role_policy_attachment.alb_controller
  ]
}
