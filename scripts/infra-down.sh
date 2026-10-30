#!/usr/bin/env bash
# =============================================================
# Phase 1 Teardown — destroys ALL AWS resources to stop billing
#
# Safe teardown order (descending dependency):
#   1. Helm releases that own AWS resources (ELBs, node ports)
#   2. Kubernetes LoadBalancer services  → releases AWS ELBs
#   3. Kubernetes PVCs                  → releases EBS volumes
#   4. Kubernetes namespaces            → clears remaining objects
#   5. terraform destroy                → EKS → VPC → IAM → ECR → CW
#
# Why this order matters:
#   - K8s Services of type LoadBalancer create AWS ELBs that are
#     NOT tracked by Terraform. If the VPC is destroyed first the
#     ELB hangs in a broken state and the VPC delete times out.
#   - K8s PVCs provision EBS volumes outside Terraform state.
#     Deleting the cluster with volumes attached orphans them and
#     leaves paid EBS volumes running.
# =============================================================
set -euo pipefail

TERRAFORM_DIR="$(dirname "$0")/../terraform"

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
echo "▶ 1/5  Uninstalling Helm releases"
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
  echo "     (safe only if cluster was never fully provisioned)"
fi

# ── Step 2: LoadBalancer services → releases AWS ELBs ────────
echo ""
echo "▶ 2/5  Deleting LoadBalancer services (releases AWS ELBs)"
if kube_available; then
  for ns in sre-ai-agent sre-ai-agent-llm monitoring chaos; do
    LB_SVCS=$(kubectl get svc -n "$ns" \
      --field-selector spec.type=LoadBalancer \
      -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)
    for svc in $LB_SVCS; do
      echo "  Deleting svc/$svc in ns/$ns..."
      # --wait=false + force avoids timeout exit on slow ELB deregistration.
      # The sleep 30 below gives AWS time to fully release the ELB.
      kubectl delete svc "$svc" -n "$ns" --wait=false --grace-period=0 --force \
        2>/dev/null || true
    done
  done
  # Wait for ELBs to fully deregister in AWS before VPC teardown
  echo "  Waiting 30s for ELBs to deregister..."
  sleep 30
  echo "  ✓ LoadBalancer services removed"
else
  echo "  ⚠  kubectl not connected — skipping LoadBalancer cleanup"
fi

# ── Step 3: PVCs → releases EBS volumes ──────────────────────
echo ""
echo "▶ 3/5  Deleting PVCs (releases EBS volumes)"
if kube_available; then
  for ns in sre-ai-agent sre-ai-agent-llm monitoring chaos; do
    # Delete regular PVCs
    kubectl delete pvc --all -n "$ns" --wait=true --timeout=120s \
      2>/dev/null || echo "  ℹ  No PVCs in $ns"

    # StatefulSet volumeClaimTemplates create PVCs that survive
    # namespace deletion. Delete them explicitly by label.
    STS_PVCS=$(kubectl get pvc -n "$ns" \
      -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)
    for pvc in $STS_PVCS; do
      echo "  Force-deleting pvc/$pvc in ns/$ns..."
      kubectl delete pvc "$pvc" -n "$ns" --wait=true --timeout=60s \
        2>/dev/null || true
    done
  done
  # Give EBS time to detach before cluster nodes are terminated
  echo "  Waiting 20s for EBS volumes to detach..."
  sleep 20
  echo "  ✓ PVCs removed"
else
  echo "  ⚠  kubectl not connected — skipping PVC cleanup"
fi

# ── Step 4: Namespaces (clears remaining K8s objects) ─────────
echo ""
echo "▶ 4/5  Deleting application namespaces"
if kube_available; then
  for ns in sre-ai-agent sre-ai-agent-llm monitoring chaos; do
    kubectl delete namespace "$ns" --wait=true --timeout=120s \
      2>/dev/null || echo "  ℹ  Namespace $ns already gone"
  done
  echo "  ✓ Namespaces removed"
else
  echo "  ⚠  kubectl not connected — skipping namespace cleanup"
fi

# ── Step 5: terraform destroy ────────────────────────────────
echo ""
echo "▶ 5/5  terraform destroy (EKS → VPC → IAM → ECR → CloudWatch)"
echo "  This takes ~10 minutes."
cd "$TERRAFORM_DIR"
terraform destroy -auto-approve

echo ""
echo "═══════════════════════════════════════════════════════"
echo "  ✅  All infrastructure destroyed."
echo ""
echo "  Note: ECR repos are deleted by Terraform only if empty."
echo "  To force-delete images before re-destroy, run:"
echo "    aws ecr batch-delete-image --region ap-south-1 \\"
echo "      --repository-name sre-ai-agent-app \\"
echo "      --image-ids \"\$(aws ecr list-images --region ap-south-1 \\"
echo "        --repository-name sre-ai-agent-app --query 'imageIds' --output json)\""
echo "    aws ecr batch-delete-image --region ap-south-1 \\"
echo "      --repository-name sre-ai-agent-llm \\"
echo "      --image-ids \"\$(aws ecr list-images --region ap-south-1 \\"
echo "        --repository-name sre-ai-agent-llm --query 'imageIds' --output json)\""
echo "═══════════════════════════════════════════════════════"
