#!/usr/bin/env bash
# =============================================================
# Phase 22-A  Infrastructure Bootstrap via Terraform
# What it does:
#   1. Checks prerequisites (terraform, aws cli, kubectl, helm)
#   2. Runs terraform init + plan + apply (VPC, EKS, IAM, ECR, CW)
#   3. Updates your kubeconfig
#   4. Verifies nodes are Ready
# Run: bash scripts/infra-up.sh
# =============================================================
set -euo pipefail

TERRAFORM_DIR="$(dirname "$0")/../terraform"

echo "═══════════════════════════════════════════════════════"
echo "  SRE-AI-Agent  ·  Phase 1  ·  Infrastructure Up (Terraform)"
echo "═══════════════════════════════════════════════════════"

# ── Pre-flight ───────────────────────────────────────────────
echo ""
echo "▶ Pre-flight checks"
for cmd in terraform aws kubectl helm; do
  command -v "$cmd" &>/dev/null || { echo "  ✗ $cmd not found — see docs/runbook-deployment.md"; exit 1; }
done
echo "  ✓ terraform, aws, kubectl, helm found"

terraform version | head -1

aws sts get-caller-identity --query 'Account' --output text &>/dev/null || \
  { echo "  ✗ AWS CLI not authenticated — run: aws configure"; exit 1; }
echo "  ✓ AWS CLI authenticated (account: $(aws sts get-caller-identity --query Account --output text))"

# ── Terraform ────────────────────────────────────────────────
cd "$TERRAFORM_DIR"

if [ ! -f "terraform.tfvars" ]; then
  echo ""
  echo "  ✗ terraform/terraform.tfvars not found"
  echo "    Run: cp terraform/terraform.tfvars.template terraform/terraform.tfvars"
  echo "    Then fill in your AWS account ID."
  exit 1
fi

echo ""
echo "▶ terraform init"
terraform init -upgrade

echo ""
echo "▶ terraform plan"
terraform plan -out=tfplan

echo ""
echo "─────────────────────────────────────────────────────"
echo "  Review the plan above."
read -r -p "  Apply? (yes/no): " CONFIRM
[[ "$CONFIRM" == "yes" ]] || { echo "Aborted."; exit 0; }

echo ""
echo "▶ terraform apply  (EKS creation takes ~15 min)"
terraform apply tfplan
rm -f tfplan

# ── Update kubeconfig ────────────────────────────────────────
echo ""
echo "▶ Updating kubeconfig"
CLUSTER=$(terraform output -raw cluster_name)
REGION="ap-south-1"
aws eks update-kubeconfig --region "$REGION" --name "$CLUSTER"
echo "  ✓ kubeconfig updated for cluster: $CLUSTER"

# ── Verify nodes ─────────────────────────────────────────────
echo ""
echo "▶ Verifying nodes"
kubectl wait --for=condition=Ready nodes --all --timeout=300s
kubectl get nodes -o wide

# ── ALB Controller (Helm) ────────────────────────────────────
# Installed here (not in Terraform) to avoid Helm provider
# repo-cache issues during terraform apply.
echo ""
echo "▶ Installing AWS Load Balancer Controller (Helm)"
ALB_ROLE_ARN=$(terraform output -raw alb_controller_role_arn)

helm repo add eks https://aws.github.io/eks-charts
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

echo "  ✓ ALB Controller installed"
kubectl get pods -n kube-system | grep aws-load-balancer

# ── Print outputs ────────────────────────────────────────────
echo ""
echo "▶ Terraform outputs (save these for later phases)"
terraform output

echo ""
echo "═══════════════════════════════════════════════════════"
echo "  ✅  Phase 1 complete — Infrastructure is live"
echo "  Next: bash scripts/deploy-pgvector.sh  (Phase 2)"
echo "═══════════════════════════════════════════════════════"
