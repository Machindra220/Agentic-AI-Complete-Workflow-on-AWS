#!/usr/bin/env bash
# =============================================================
# Phase 1 — Infrastructure Bootstrap (Terraform + Helm)
# Fully automated: no interactive prompts.
# Usage: bash scripts/infra-up.sh
# =============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TERRAFORM_DIR="${SCRIPT_DIR}/../terraform"
REGION="ap-south-1"

echo "═══════════════════════════════════════════════════════"
echo "  Phase 1 — Infrastructure Bootstrap"
echo "═══════════════════════════════════════════════════════"

# ── Pre-flight ───────────────────────────────────────────────
echo ""
echo "▶ [1/5] Pre-flight checks"
for cmd in terraform aws kubectl helm; do
  command -v "$cmd" &>/dev/null || { echo "  ✗ $cmd not found"; exit 1; }
done
aws sts get-caller-identity --query Account --output text &>/dev/null || \
  { echo "  ✗ AWS CLI not authenticated — run: aws configure"; exit 1; }
echo "  ✓ All tools ready (account: $(aws sts get-caller-identity --query Account --output text))"

[ -f "${TERRAFORM_DIR}/terraform.tfvars" ] || \
  { echo "  ✗ terraform/terraform.tfvars not found. Copy from terraform.tfvars.template and fill in aws_account_id."; exit 1; }

# ── Terraform ────────────────────────────────────────────────
echo ""
echo "▶ [2/5] Terraform init + apply"
cd "$TERRAFORM_DIR"
terraform init -upgrade -input=false
terraform apply -auto-approve -input=false
echo "  ✓ Terraform apply complete"

# ── kubeconfig ───────────────────────────────────────────────
echo ""
echo "▶ [3/5] Update kubeconfig"
CLUSTER=$(terraform output -raw cluster_name)
aws eks update-kubeconfig --region "$REGION" --name "$CLUSTER"
kubectl wait --for=condition=Ready nodes --all --timeout=300s
echo "  ✓ Nodes ready:"
kubectl get nodes

# ── ALB Controller ───────────────────────────────────────────
echo ""
echo "▶ [4/5] Install ALB Controller"
ALB_ROLE_ARN=$(terraform output -raw alb_controller_role_arn)
helm repo add eks https://aws.github.io/eks-charts 2>/dev/null || true
helm repo update

helm upgrade --install aws-load-balancer-controller \
  eks/aws-load-balancer-controller \
  --namespace kube-system \
  --version "1.7.2" \
  --set clusterName="${CLUSTER}" \
  --set serviceAccount.create=true \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn=${ALB_ROLE_ARN}" \
  --set enableCertManager=false \
  --wait --timeout 120s
echo "  ✓ ALB Controller running:"
kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller

# ── Summary ──────────────────────────────────────────────────
echo ""
echo "▶ [5/5] Outputs"
terraform output

echo ""
echo "═══════════════════════════════════════════════════════"
echo "  ✅  Phase 1 complete"
echo "═══════════════════════════════════════════════════════"
