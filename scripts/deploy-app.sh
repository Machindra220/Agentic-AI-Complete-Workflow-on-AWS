#!/usr/bin/env bash
# =============================================================
# Phase 3 — FastAPI App: build → ECR push → EKS deploy
# Usage: bash scripts/deploy-app.sh
# =============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="${SCRIPT_DIR}/../app"
MANIFESTS="${SCRIPT_DIR}/../k8s/app"
NAMESPACE="sre-ai-agent"
IMAGE_TAG="${IMAGE_TAG:-latest}"

echo "═══════════════════════════════════════════════════════"
echo "  Phase 3 — FastAPI App Deploy"
echo "═══════════════════════════════════════════════════════"

# ── Load .env (strips Windows CRLF) ─────────────────────────
ENV_FILE="${SCRIPT_DIR}/../.env"
[[ -f "$ENV_FILE" ]] && { set -a; source <(tr -d '\r' < "$ENV_FILE"); set +a; }

# ── Pre-flight ───────────────────────────────────────────────
echo ""
echo "▶ [1/6] Pre-flight checks"
: "${AWS_ACCOUNT_ID:?AWS_ACCOUNT_ID not set — add to .env}"
: "${AWS_REGION:?AWS_REGION not set — add to .env}"
kubectl cluster-info &>/dev/null || { echo "  ✗ kubectl not connected. Run Phase 1 first."; exit 1; }
kubectl get namespace "$NAMESPACE" &>/dev/null || { echo "  ✗ Namespace $NAMESPACE missing. Run Phase 1 first."; exit 1; }
command -v docker &>/dev/null || { echo "  ✗ docker not found. Install Docker Desktop."; exit 1; }
echo "  ✓ kubectl connected, docker available"

ECR_REGISTRY="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
ECR_REPO="${ECR_REGISTRY}/sre-ai-agent-app"
FULL_IMAGE="${ECR_REPO}:${IMAGE_TAG}"

# ── ECR Login ────────────────────────────────────────────────
echo ""
echo "▶ [2/6] Logging in to ECR"
aws ecr get-login-password --region "${AWS_REGION}" \
  | docker login --username AWS --password-stdin "${ECR_REGISTRY}"
echo "  ✓ ECR login successful"

# ── Build image ──────────────────────────────────────────────
echo ""
echo "▶ [3/6] Building Docker image"
docker build \
  --platform linux/amd64 \
  -t "${FULL_IMAGE}" \
  "${APP_DIR}"
echo "  ✓ Image built: ${FULL_IMAGE}"

# ── Push to ECR ──────────────────────────────────────────────
echo ""
echo "▶ [4/6] Pushing image to ECR"
docker push "${FULL_IMAGE}"
echo "  ✓ Image pushed to ECR"

# ── Patch deployment manifest with real ECR image ────────────
echo ""
echo "▶ [5/6] Deploying to EKS"

# Use sed to inject the real image into the deployment manifest
# Works on both Linux and Git Bash on Windows
MANIFEST_TMP=$(mktemp)
sed "s|PLACEHOLDER_ECR_URL:latest|${FULL_IMAGE}|g" \
  "${MANIFESTS}/deployment.yaml" > "${MANIFEST_TMP}"

kubectl apply -f "${MANIFEST_TMP}"
kubectl apply -f "${MANIFESTS}/service.yaml"
kubectl apply -f "${MANIFESTS}/hpa.yaml"
rm -f "${MANIFEST_TMP}"

# Update the running deployment image (idempotent on re-runs)
kubectl set image deployment/sre-demo-api \
  api="${FULL_IMAGE}" \
  -n "${NAMESPACE}" 2>/dev/null || true

echo "  ✓ Manifests applied"

# ── Wait for rollout ─────────────────────────────────────────
echo ""
echo "▶ [6/6] Waiting for rollout (timeout: 3 min)"
kubectl rollout status deployment/sre-demo-api \
  -n "${NAMESPACE}" \
  --timeout=180s

echo ""
echo "  Pod status:"
kubectl get pods -n "${NAMESPACE}" -l app=sre-demo-api

# ── Print LoadBalancer URL ───────────────────────────────────
echo ""
echo "  Waiting up to 90s for LoadBalancer hostname..."
LB_HOSTNAME=""
for i in $(seq 1 18); do
  LB_HOSTNAME=$(kubectl get svc sre-demo-api -n "${NAMESPACE}" \
    -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
  [[ -n "$LB_HOSTNAME" ]] && break
  echo "  ... waiting (${i}/18)"
  sleep 5
done

echo ""
echo "═══════════════════════════════════════════════════════"
echo "  ✅  Phase 3 complete"
if [[ -n "$LB_HOSTNAME" ]]; then
  echo "  App URL:     http://${LB_HOSTNAME}/api/health"
  echo "  Metrics URL: http://${LB_HOSTNAME}/metrics"
else
  echo "  LoadBalancer still provisioning — check with:"
  echo "  kubectl get svc sre-demo-api -n ${NAMESPACE}"
fi
echo "═══════════════════════════════════════════════════════"
