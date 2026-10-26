#!/usr/bin/env bash
# Install and verify AWS Load Balancer Controller
# Run: bash scripts/install-alb-controller.sh
set -euo pipefail

CLUSTER="sre-ai-agent-cluster"
REGION="ap-south-1"
ALB_ROLE_ARN="arn:aws:iam::893483579480:role/sre-ai-agent-cluster-alb-controller"

echo "▶ Adding EKS Helm repo"
helm repo add eks https://aws.github.io/eks-charts 2>/dev/null || true
helm repo update

echo "▶ Installing ALB Controller"
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

echo "▶ Verifying"
kubectl rollout status deployment/aws-load-balancer-controller -n kube-system --timeout=120s
kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller

echo ""
echo "✅  ALB Controller is running"
