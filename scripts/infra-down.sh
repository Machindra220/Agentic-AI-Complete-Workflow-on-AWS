#!/usr/bin/env bash
# =============================================================
# Phase 1 Teardown — destroys ALL AWS resources to stop billing
#
# Safe teardown order (descending dependency):
#   1. Helm releases that own AWS resources (ELBs, node ports)
#   2. Kubernetes LoadBalancer services  → releases AWS ELBs
#   3. AWS NLB + SG explicit cleanup    → unblocks VPC deletion
#   4. Kubernetes PVCs                  → releases EBS volumes
#   5. Kubernetes namespaces            → clears remaining objects
#   6. terraform destroy                → EKS → VPC → IAM → ECR → CW
#
# Why this order matters:
#   - K8s Services of type LoadBalancer create AWS NLBs that are
#     NOT tracked by Terraform. If the VPC is destroyed first the
#     NLB hangs in a broken state and the VPC delete times out.
#   - NLB security groups survive even after the NLB is gone —
#     explicitly deleted in Step 3 to unblock VPC deletion.
#   - K8s PVCs provision EBS volumes outside Terraform state.
#     Deleting the cluster with volumes attached orphans them and
#     leaves paid EBS volumes running.
# =============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TERRAFORM_DIR="${SCRIPT_DIR}/../terraform"
REGION="ap-south-1"

# Read VPC ID from Terraform state (needed for Step 3 cleanup)
get_vpc_id() {
  cd "$TERRAFORM_DIR"
  terraform output -raw vpc_id 2>/dev/null || true
}

echo "═══════════════════════════════════════════════════════"
echo "  SRE-AI-Agent  ·  Infrastructure Teardown"
echo "  This will DELETE all AWS resources and stop billing."
echo "═══════════════════════════════════════════════════════"
echo ""
read -r -p "  Type 'destroy' to confirm: " CONFIRM
[[ "$CONFIRM" == "destroy" ]] || { echo "Aborted."; exit 0; }

# ── Helper: skip gracefully if kubectl/helm not connected ────
kube_available() {
  kubectl cluster-info &>/dev/null 2>&1
}

# ── Step 1: Helm releases (reverse install order) ────────────
echo ""
echo "▶ 1/6  Uninstalling Helm releases"
if kube_available; then
  for release_ns in \
    "chaoskube:chaos" \
    "promtail:monitoring" \
    "kube-prometheus-stack:monitoring" \
    "aws-load-balancer-controller:kube-system"; do
    release="${release_ns%%:*}"
    ns="${release_ns##*:}"
    if helm status "$release" -n "$ns" &>/dev/null; then
      echo "  Uninstalling $release (ns: $ns)..."
      helm uninstall "$release" -n "$ns" --wait --timeout 120s || \
        echo "  ⚠  $release not found or already removed"
    fi
  done
  echo "  ✓ Helm releases removed"
else
  echo "  ⚠  kubectl not connected — skipping Helm uninstalls"
fi

# ── Step 2: LoadBalancer services → triggers NLB deletion ────
echo ""
echo "▶ 2/6  Deleting LoadBalancer services (triggers AWS NLB deletion)"
if kube_available; then
  for ns in sre-ai-agent sre-ai-agent-llm monitoring chaos; do
    LB_SVCS=$(kubectl get svc -n "$ns" \
      --field-selector spec.type=LoadBalancer \
      -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)
    for svc in $LB_SVCS; do
      echo "  Deleting svc/$svc in ns/$ns..."
      kubectl delete svc "$svc" -n "$ns" --wait=false --grace-period=0 --force \
        2>/dev/null || true
    done
  done
  echo "  Waiting 60s for NLBs to deregister in AWS..."
  sleep 60
  echo "  ✓ LoadBalancer services removed"
else
  echo "  ⚠  kubectl not connected — skipping LoadBalancer cleanup"
fi

# ── Step 3: Explicit NLB + SG cleanup (unblocks VPC deletion) ─
echo ""
echo "▶ 3/6  Cleaning up leftover NLBs and security groups"
VPC_ID=$(get_vpc_id)
if [[ -n "$VPC_ID" ]]; then
  # Delete any remaining NLBs in this VPC
  NLB_ARNS=$(aws elbv2 describe-load-balancers --region "$REGION" \
    --query "LoadBalancers[?VpcId=='${VPC_ID}'].LoadBalancerArn" \
    --output text 2>/dev/null || true)
  for arn in $NLB_ARNS; do
    echo "  Deleting NLB: $arn"
    aws elbv2 delete-load-balancer --region "$REGION" --load-balancer-arn "$arn" || true
  done
  if [[ -n "$NLB_ARNS" ]]; then
    echo "  Waiting 30s for NLBs to fully deregister..."
    sleep 30
  fi

  # Delete any leftover target groups
  TG_ARNS=$(aws elbv2 describe-target-groups --region "$REGION" \
    --query 'TargetGroups[*].TargetGroupArn' --output text 2>/dev/null || true)
  for arn in $TG_ARNS; do
    aws elbv2 delete-target-group --region "$REGION" --target-group-arn "$arn" \
      2>/dev/null || true
  done

  # Delete leftover ENIs (NLB leaves ENIs behind)
  ENI_IDS=$(aws ec2 describe-network-interfaces --region "$REGION" \
    --filters "Name=vpc-id,Values=${VPC_ID}" \
    --query 'NetworkInterfaces[*].NetworkInterfaceId' \
    --output text 2>/dev/null || true)
  for eni in $ENI_IDS; do
    echo "  Deleting ENI: $eni"
    aws ec2 delete-network-interface --region "$REGION" \
      --network-interface-id "$eni" 2>/dev/null || true
  done

  # Delete leftover non-default security groups
  SG_IDS=$(aws ec2 describe-security-groups --region "$REGION" \
    --filters "Name=vpc-id,Values=${VPC_ID}" \
    --query 'SecurityGroups[?GroupName!=`default`].GroupId' \
    --output text 2>/dev/null || true)
  for sg in $SG_IDS; do
    echo "  Deleting SG: $sg"
    aws ec2 delete-security-group --region "$REGION" --group-id "$sg" \
      2>/dev/null || true
  done

  echo "  ✓ NLB/ENI/SG cleanup complete"
else
  echo "  ⚠  Could not read VPC ID from Terraform state — skipping NLB/SG cleanup"
fi

# ── Step 4: PVCs → releases EBS volumes ──────────────────────
echo ""
echo "▶ 4/6  Deleting PVCs (releases EBS volumes)"
if kube_available; then
  for ns in sre-ai-agent sre-ai-agent-llm monitoring chaos; do
    kubectl delete pvc --all -n "$ns" --wait=true --timeout=120s \
      2>/dev/null || echo "  ℹ  No PVCs in $ns"
    STS_PVCS=$(kubectl get pvc -n "$ns" \
      -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)
    for pvc in $STS_PVCS; do
      echo "  Force-deleting pvc/$pvc in ns/$ns..."
      kubectl delete pvc "$pvc" -n "$ns" --wait=true --timeout=60s \
        2>/dev/null || true
    done
  done
  echo "  Waiting 20s for EBS volumes to detach..."
  sleep 20
  echo "  ✓ PVCs removed"
else
  echo "  ⚠  kubectl not connected — skipping PVC cleanup"
fi

# ── Step 5: Namespaces ────────────────────────────────────────
echo ""
echo "▶ 5/6  Deleting application namespaces"
if kube_available; then
  for ns in sre-ai-agent sre-ai-agent-llm monitoring chaos; do
    kubectl delete namespace "$ns" --wait=true --timeout=120s \
      2>/dev/null || echo "  ℹ  Namespace $ns already gone"
  done
  echo "  ✓ Namespaces removed"
else
  echo "  ⚠  kubectl not connected — skipping namespace cleanup"
fi

# ── Step 6: terraform destroy ────────────────────────────────
echo ""
echo "▶ 6/6  terraform destroy (EKS → VPC → IAM → ECR → CloudWatch)"
echo "  This takes ~10 minutes."
cd "$TERRAFORM_DIR"
terraform destroy -auto-approve

echo ""
echo "═══════════════════════════════════════════════════════"
echo "  ✅  All infrastructure destroyed. Billing stopped."
echo "═══════════════════════════════════════════════════════"
