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

# ALB Controller is installed via Helm in scripts/infra-up.sh
# (after terraform apply + kubeconfig update) to avoid Helm
# provider repo-cache issues during terraform apply.
