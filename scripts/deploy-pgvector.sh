#!/usr/bin/env bash
# =============================================================
# Phase 2 — pgvector StatefulSet + Runbook Seed
# Usage: bash scripts/deploy-pgvector.sh
# =============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MANIFESTS="${SCRIPT_DIR}/../k8s/pgvector"
AGENT_DIR="${SCRIPT_DIR}/../agent"
NAMESPACE="sre-ai-agent-llm"

echo "═══════════════════════════════════════════════════════"
echo "  Phase 2 — pgvector + Runbook Seed"
echo "═══════════════════════════════════════════════════════"

# ── Load .env (strips Windows CRLF) ─────────────────────────
ENV_FILE="${SCRIPT_DIR}/../.env"
[[ -f "$ENV_FILE" ]] && { set -a; source <(tr -d '\r' < "$ENV_FILE"); set +a; }

# ── Pre-flight ───────────────────────────────────────────────
echo ""
echo "▶ [1/6] Pre-flight checks"
kubectl cluster-info &>/dev/null || { echo "  ✗ kubectl not connected. Run Phase 1 first."; exit 1; }
kubectl get namespace "$NAMESPACE" &>/dev/null || { echo "  ✗ Namespace $NAMESPACE missing. Run Phase 1 first."; exit 1; }
: "${PG_PASSWORD:?PG_PASSWORD not set — add PG_PASSWORD=<value> to .env}"
PG_USER="${PG_USER:-postgres}"
PG_DB="${PG_DB:-sre_agent}"
echo "  ✓ Cluster connected, namespace exists, PG_PASSWORD set"

# ── Create secret ────────────────────────────────────────────
echo ""
echo "▶ [2/6] Creating pgvector secret"
kubectl create secret generic pgvector-secret \
  --namespace "$NAMESPACE" \
  --from-literal=POSTGRES_USER="${PG_USER}" \
  --from-literal=POSTGRES_PASSWORD="${PG_PASSWORD}" \
  --from-literal=POSTGRES_DB="${PG_DB}" \
  --dry-run=client -o yaml | kubectl apply -f -
echo "  ✓ Secret applied"

# ── Deploy manifests ─────────────────────────────────────────
echo ""
echo "▶ [3/6] Applying pgvector manifests"
kubectl apply -f "${MANIFESTS}/statefulset.yaml"
kubectl apply -f "${MANIFESTS}/service.yaml"
echo "  ✓ Manifests applied"

# ── Wait for pod Ready (with auto-diagnosis on failure) ───────
echo ""
echo "▶ [4/6] Waiting for pgvector pod to be Ready (timeout: 5 min)"

wait_for_pod() {
  local deadline=$(( $(date +%s) + 300 ))
  while [[ $(date +%s) -lt $deadline ]]; do
    local phase
    phase=$(kubectl get pod pgvector-0 -n "$NAMESPACE" \
      -o jsonpath='{.status.phase}' 2>/dev/null || echo "Pending")
    local ready
    ready=$(kubectl get pod pgvector-0 -n "$NAMESPACE" \
      -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null || echo "false")

    if [[ "$ready" == "true" ]]; then
      return 0
    fi

    # Print current status every 10s
    local reason
    reason=$(kubectl get pod pgvector-0 -n "$NAMESPACE" \
      -o jsonpath='{.status.containerStatuses[0].state.waiting.reason}' 2>/dev/null || echo "")
    echo "  ... status: ${phase} ${reason}"

    # Early exit on unrecoverable states
    if [[ "$reason" == "ErrImagePull" || "$reason" == "InvalidImageName" ]]; then
      echo "  ✗ Image pull failed — check image name in statefulset.yaml"
      kubectl describe pod pgvector-0 -n "$NAMESPACE" | tail -20
      exit 1
    fi

    sleep 10
  done

  # Timed out — print diagnosis automatically
  echo ""
  echo "  ✗ Pod not Ready after 5 minutes. Diagnosis:"
  echo ""
  echo "  ── kubectl describe pod ──────────────────────────"
  kubectl describe pod pgvector-0 -n "$NAMESPACE" | grep -A 20 "Events:"
  echo ""
  echo "  ── kubectl logs (previous) ──────────────────────"
  kubectl logs pgvector-0 -n "$NAMESPACE" --previous 2>/dev/null || \
    kubectl logs pgvector-0 -n "$NAMESPACE" 2>/dev/null || \
    echo "  (no logs yet)"
  echo ""
  echo "  ── PVC status ───────────────────────────────────"
  kubectl get pvc -n "$NAMESPACE"
  exit 1
}

wait_for_pod
echo "  ✓ pgvector pod Ready"
kubectl get pods -n "$NAMESPACE" -l app=pgvector

# ── Enable pgvector extension + create table ──────────────────
echo ""
echo "▶ [5/6] Enabling pgvector extension + creating table"
kubectl exec -n "$NAMESPACE" pgvector-0 -- \
  psql -U postgres -d sre_agent -c "CREATE EXTENSION IF NOT EXISTS vector;"

kubectl exec -n "$NAMESPACE" pgvector-0 -- psql -U postgres -d sre_agent -c "
  CREATE TABLE IF NOT EXISTS runbook_chunks (
    id         SERIAL PRIMARY KEY,
    title      TEXT NOT NULL,
    content    TEXT NOT NULL,
    embedding  VECTOR(1536),
    created_at TIMESTAMPTZ DEFAULT NOW()
  );
  CREATE INDEX IF NOT EXISTS runbook_chunks_embedding_idx
    ON runbook_chunks USING ivfflat (embedding vector_cosine_ops)
    WITH (lists = 10);
"
echo "  ✓ Extension and table ready"

# ── Seed runbooks ────────────────────────────────────────────
echo ""
echo "▶ [6/6] Seeding SRE runbooks"
# Detect python (Windows uses 'python', Linux/Mac uses 'python3')
PYTHON=""
for cmd in python3 python; do
  if command -v "$cmd" &>/dev/null && "$cmd" -c "import sys; sys.exit(0 if sys.version_info.major==3 else 1)" 2>/dev/null; then
    PYTHON="$cmd"; break
  fi
done

if [[ -n "$PYTHON" ]]; then
  "$PYTHON" -m pip install -q psycopg2-binary boto3 2>/dev/null || true
  kubectl port-forward -n "$NAMESPACE" svc/pgvector 5432:5432 &
  PF_PID=$!
  sleep 3
  "$PYTHON" "${AGENT_DIR}/seed_runbooks.py"
  kill $PF_PID 2>/dev/null || true
  echo "  ✓ Runbooks seeded"
else
  echo "  ⚠  Python 3 not found — skipping seed. Run manually:"
  echo "     kubectl port-forward -n $NAMESPACE svc/pgvector 5432:5432 &"
  echo "     python agent/seed_runbooks.py"
fi

# ── Verify ───────────────────────────────────────────────────
echo ""
ROW_COUNT=$(kubectl exec -n "$NAMESPACE" pgvector-0 -- \
  psql -U postgres -d sre_agent -t -c "SELECT COUNT(*) FROM runbook_chunks;" \
  2>/dev/null | tr -d ' \n')
echo "  Runbook chunks in DB: ${ROW_COUNT}"

echo ""
echo "═══════════════════════════════════════════════════════"
echo "  ✅  Phase 2 complete"
echo "  pgvector: pgvector.${NAMESPACE}.svc.cluster.local:5432"
echo "═══════════════════════════════════════════════════════"
