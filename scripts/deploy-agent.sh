#!/usr/bin/env bash
# =============================================================
# Phase 4 — LangGraph Agent: build → ECR push → EKS deploy
# Usage: bash scripts/deploy-agent.sh
# =============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TERRAFORM_DIR="${SCRIPT_DIR}/../terraform"
MANIFESTS="${SCRIPT_DIR}/../k8s/agent"
NAMESPACE="sre-ai-agent-llm"
IMAGE_TAG="${IMAGE_TAG:-latest}"

echo "═══════════════════════════════════════════════════════"
echo "  Phase 4 — LangGraph Agent Deploy"
echo "═══════════════════════════════════════════════════════"

# ── Load .env (strips Windows CRLF) ─────────────────────────
ENV_FILE="${SCRIPT_DIR}/../.env"
[[ -f "$ENV_FILE" ]] && { set -a; source <(tr -d '\r' < "$ENV_FILE"); set +a; }

# ── Pre-flight ───────────────────────────────────────────────
echo ""
echo "▶ [1/7] Pre-flight checks"
: "${AWS_ACCOUNT_ID:?AWS_ACCOUNT_ID not set — add to .env}"
: "${AWS_REGION:?AWS_REGION not set — add to .env}"
kubectl cluster-info &>/dev/null || { echo "  ✗ kubectl not connected. Run Phase 1 first."; exit 1; }
kubectl get namespace "$NAMESPACE" &>/dev/null || { echo "  ✗ Namespace $NAMESPACE missing. Run Phase 1 first."; exit 1; }
kubectl get secret pgvector-secret -n "$NAMESPACE" &>/dev/null || \
  { echo "  ✗ pgvector-secret not found. Run Phase 2 first."; exit 1; }
command -v docker &>/dev/null || { echo "  ✗ docker not found. Install Docker Desktop."; exit 1; }
echo "  ✓ All checks passed"

ECR_REGISTRY="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
ECR_REPO="${ECR_REGISTRY}/sre-ai-agent-llm"
FULL_IMAGE="${ECR_REPO}:${IMAGE_TAG}"

# ── Fetch IRSA role ARN from Terraform output ────────────────
echo ""
echo "▶ [2/7] Fetching IRSA role ARN from Terraform"
AGENT_ROLE_ARN=$(cd "$TERRAFORM_DIR" && terraform output -raw sre_agent_role_arn 2>/dev/null) || \
  { echo "  ✗ Could not read sre_agent_role_arn. Run Phase 1 (terraform apply) first."; exit 1; }
echo "  ✓ IRSA role: ${AGENT_ROLE_ARN}"

# ── ECR Login ────────────────────────────────────────────────
echo ""
echo "▶ [3/7] Logging in to ECR"
aws ecr get-login-password --region "${AWS_REGION}" \
  | docker login --username AWS --password-stdin "${ECR_REGISTRY}"
echo "  ✓ ECR login successful"

# ── Build image ──────────────────────────────────────────────
echo ""
echo "▶ [4/7] Building Docker image"
# Build context is repo root so agent/ folder is accessible
docker build \
  --platform linux/amd64 \
  -f "${SCRIPT_DIR}/../agent/Dockerfile" \
  -t "${FULL_IMAGE}" \
  "${SCRIPT_DIR}/.."
echo "  ✓ Image built: ${FULL_IMAGE}"

# ── Push to ECR ──────────────────────────────────────────────
echo ""
echo "▶ [5/7] Pushing image to ECR"
docker push "${FULL_IMAGE}"
echo "  ✓ Image pushed to ECR"

# ── Deploy manifests ─────────────────────────────────────────
echo ""
echo "▶ [6/7] Deploying to EKS"

# Inject IRSA role ARN into ServiceAccount manifest
SA_TMP=$(mktemp)
sed "s|PLACEHOLDER_AGENT_ROLE_ARN|${AGENT_ROLE_ARN}|g" \
  "${MANIFESTS}/serviceaccount.yaml" > "${SA_TMP}"
kubectl apply -f "${SA_TMP}"
rm -f "${SA_TMP}"

# Inject ECR image into Deployment manifest
DEPLOY_TMP=$(mktemp)
sed "s|PLACEHOLDER_ECR_URL:latest|${FULL_IMAGE}|g" \
  "${MANIFESTS}/deployment.yaml" > "${DEPLOY_TMP}"
kubectl apply -f "${DEPLOY_TMP}"
rm -f "${DEPLOY_TMP}"

kubectl apply -f "${MANIFESTS}/service.yaml"

# Update running deployment image (idempotent on re-runs)
kubectl set image deployment/sre-agent \
  agent="${FULL_IMAGE}" \
  -n "${NAMESPACE}" 2>/dev/null || true

echo "  ✓ Manifests applied"

# ── Wait for rollout ─────────────────────────────────────────
echo ""
echo "▶ [7/7] Waiting for rollout (timeout: 3 min)"
kubectl rollout status deployment/sre-agent \
  -n "${NAMESPACE}" \
  --timeout=180s

echo ""
echo "  Pod status:"
kubectl get pods -n "${NAMESPACE}" -l app=sre-agent

# ── Verify agent is reachable ────────────────────────────────
echo ""
echo "  Testing agent health via port-forward..."
kubectl port-forward -n "${NAMESPACE}" svc/sre-agent 18081:8081 &
PF_PID=$!
sleep 3

HEALTH=$(curl -sf http://localhost:18081/agent/health 2>/dev/null || echo "unreachable")
kill $PF_PID 2>/dev/null || true

echo ""
echo "═══════════════════════════════════════════════════════"
echo "  ✅  Phase 4 complete"
echo "  Agent health: ${HEALTH}"
echo ""
echo "  Internal endpoint:"
echo "  http://sre-agent.${NAMESPACE}.svc.cluster.local:8081"
echo ""
echo "  Test locally:"
echo "  kubectl port-forward -n ${NAMESPACE} svc/sre-agent 18081:8081 &"
echo "  curl -X POST http://localhost:18081/agent/triage \\"
echo "    -H 'Content-Type: application/json' \\"
echo "    -d '{\"alert_name\":\"High Error Rate\",\"severity\":\"P2\",\"service\":\"sre-demo-api\",\"message\":\"5xx errors spiking\"}'"
echo "═══════════════════════════════════════════════════════"
