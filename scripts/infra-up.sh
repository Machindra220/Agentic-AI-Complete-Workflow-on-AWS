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
CLUSTER_NAME="sre-ai-agent-cluster"

# Load .env (strips Windows CRLF line endings)
ENV_FILE="${SCRIPT_DIR}/../.env"
if [[ -f "$ENV_FILE" ]]; then
  set -a; source <(tr -d '\r' < "$ENV_FILE"); set +a
fi

echo "═══════════════════════════════════════════════════════"
echo "  Phase 1 — Infrastructure Bootstrap"
echo "═══════════════════════════════════════════════════════"

# ── [1/6] Pre-flight ─────────────────────────────────────────
echo ""
echo "▶ [1/6] Pre-flight checks"
for cmd in terraform aws kubectl helm; do
  command -v "$cmd" &>/dev/null || { echo "  ✗ $cmd not found"; exit 1; }
done
ACTUAL_ACCOUNT=$(aws sts get-caller-identity --query Account --output text 2>/dev/null) || \
  { echo "  ✗ AWS CLI not authenticated — run: aws configure"; exit 1; }
echo "  ✓ All tools ready (account: ${ACTUAL_ACCOUNT})"

# Guard: .env AWS_ACCOUNT_ID must match the authenticated AWS account.
if [[ -n "${AWS_ACCOUNT_ID:-}" && "${AWS_ACCOUNT_ID}" != "${ACTUAL_ACCOUNT}" ]]; then
  echo ""
  echo "  ✗ AWS_ACCOUNT_ID mismatch!"
  echo "    .env says:    ${AWS_ACCOUNT_ID}"
  echo "    aws sts says: ${ACTUAL_ACCOUNT}"
  echo "  Fix: update AWS_ACCOUNT_ID in .env to ${ACTUAL_ACCOUNT}"
  exit 1
fi
AWS_ACCOUNT_ID="${ACTUAL_ACCOUNT}"

[ -f "${TERRAFORM_DIR}/terraform.tfvars" ] || \
  { echo "  ✗ terraform/terraform.tfvars not found. Copy from terraform.tfvars.template and fill in aws_account_id."; exit 1; }

# ── [2/6] Terraform init + apply ─────────────────────────────
echo ""
echo "▶ [2/6] Terraform init + apply"
cd "$TERRAFORM_DIR"
terraform init -upgrade -input=false

# Auto-import EKS access entry if it already exists in AWS but not in state.
# The EKS module registers the cluster creator automatically. Our eks-access.tf
# also declares the same user — on a re-run after a partial destroy this causes
# a 409 ResourceInUseException. Importing before apply resolves the conflict.
ADMIN_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:user/Machindra"
if aws eks describe-access-entry \
     --cluster-name "${CLUSTER_NAME}" \
     --principal-arn "${ADMIN_ARN}" \
     --region "${REGION}" &>/dev/null 2>&1; then
  if ! terraform state show aws_eks_access_entry.admin &>/dev/null 2>&1; then
    echo "  ℹ  EKS access entry exists in AWS but not in state — importing..."
    terraform import aws_eks_access_entry.admin \
      "${CLUSTER_NAME}:${ADMIN_ARN}" || true
  fi
fi

terraform apply -auto-approve -input=false
echo "  ✓ Terraform apply complete"

# ── [3/6] kubeconfig + node readiness ────────────────────────
echo ""
echo "▶ [3/6] Update kubeconfig + wait for nodes"
CLUSTER=$(terraform output -raw cluster_name)
aws eks update-kubeconfig --region "$REGION" --name "$CLUSTER"
kubectl wait --for=condition=Ready nodes --all --timeout=300s
echo "  ✓ Nodes ready:"
kubectl get nodes

# ── [4/6] ALB Controller ─────────────────────────────────────
echo ""
echo "▶ [4/6] Install ALB Controller"
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

# Wait for ALB controller pods to be fully Ready before proceeding.
# Ensures IRSA token is loaded and IAM permissions are active,
# preventing stale-token issues when LoadBalancer services are created.
kubectl rollout status deployment/aws-load-balancer-controller \
  -n kube-system --timeout=120s
echo "  ✓ ALB Controller running:"
kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller

# ── [5/6] Namespaces ─────────────────────────────────────────
echo ""
echo "▶ [5/6] Create application namespaces"
for ns in sre-ai-agent sre-ai-agent-llm monitoring chaos; do
  if kubectl get namespace "$ns" &>/dev/null; then
    echo "  ℹ  Namespace $ns already exists"
  else
    kubectl create namespace "$ns"
    kubectl label namespace "$ns" \
      app.kubernetes.io/managed-by=terraform \
      project=sre-ai-agent
    echo "  ✓  Namespace $ns created"
  fi
done

# ── [6/6] Summary ────────────────────────────────────────────
echo ""
echo "▶ [6/6] Terraform outputs"
terraform output

echo ""
echo "═══════════════════════════════════════════════════════"
echo "  ✅  Phase 1 complete — proceed with:"
echo "      bash scripts/deploy-pgvector.sh"
echo "═══════════════════════════════════════════════════════"
