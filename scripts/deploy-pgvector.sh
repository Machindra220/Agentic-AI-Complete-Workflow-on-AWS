#!/usr/bin/env bash
# =============================================================
# Phase 2 — pgvector StatefulSet + Runbook Seed
# Deploys pgvector on EKS and seeds SRE runbook embeddings.
# Usage: bash scripts/deploy-pgvector.sh
# =============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MANIFESTS="${SCRIPT_DIR}/../k8s/pgvector"
AGENT_DIR="${SCRIPT_DIR}/../agent"
NAMESPACE="sre-ai-agent-llm"
REGION="ap-south-1"

echo "═══════════════════════════════════════════════════════"
echo "  Phase 2 — pgvector + Runbook Seed"
echo "═══════════════════════════════════════════════════════"

# ── Pre-flight ───────────────────────────────────────────────
echo ""
echo "▶ [1/5] Pre-flight checks"
kubectl cluster-info &>/dev/null || { echo "  ✗ kubectl not connected. Run Phase 1 first."; exit 1; }
kubectl get namespace "$NAMESPACE" &>/dev/null || { echo "  ✗ Namespace $NAMESPACE missing. Run Phase 1 first."; exit 1; }
echo "  ✓ Cluster connected, namespace exists"

# ── Create secret from env ───────────────────────────────────
echo ""
echo "▶ [2/5] Creating pgvector secret"
: "${PG_PASSWORD:?Set PG_PASSWORD in .env}"
: "${PG_USER:=postgres}"
: "${PG_DB:=sre_agent}"

kubectl create secret generic pgvector-secret \
  --namespace "$NAMESPACE" \
  --from-literal=POSTGRES_USER="${PG_USER}" \
  --from-literal=POSTGRES_PASSWORD="${PG_PASSWORD}" \
  --from-literal=POSTGRES_DB="${PG_DB}" \
  --dry-run=client -o yaml | kubectl apply -f -
echo "  ✓ Secret created"

# ── Deploy manifests ─────────────────────────────────────────
echo ""
echo "▶ [3/5] Applying pgvector manifests"
kubectl apply -f "${MANIFESTS}/statefulset.yaml"
kubectl apply -f "${MANIFESTS}/service.yaml"
echo "  ✓ Manifests applied"

# ── Wait for pod Ready ───────────────────────────────────────
echo ""
echo "▶ [4/5] Waiting for pgvector pod to be Ready"
kubectl rollout status statefulset/pgvector -n "$NAMESPACE" --timeout=300s
echo "  ✓ pgvector pod Ready:"
kubectl get pods -n "$NAMESPACE" -l app=pgvector

# ── Enable pgvector extension ─────────────────────────────────
echo ""
echo "▶ [5/6] Enabling pgvector extension + creating tables"
kubectl exec -n "$NAMESPACE" pgvector-0 -- \
  psql -U postgres -d sre_agent -c "CREATE EXTENSION IF NOT EXISTS vector;"

kubectl exec -n "$NAMESPACE" pgvector-0 -- \
  psql -U postgres -d sre_agent -c "
    CREATE TABLE IF NOT EXISTS runbook_chunks (
      id        SERIAL PRIMARY KEY,
      title     TEXT NOT NULL,
      content   TEXT NOT NULL,
      embedding VECTOR(1536),
      created_at TIMESTAMPTZ DEFAULT NOW()
    );
    CREATE INDEX IF NOT EXISTS runbook_chunks_embedding_idx
      ON runbook_chunks USING ivfflat (embedding vector_cosine_ops)
      WITH (lists = 10);
  "
echo "  ✓ Extension and table created"

# ── Seed runbooks ────────────────────────────────────────────
echo ""
echo "▶ [6/6] Seeding SRE runbooks"
# Check Python is available
if command -v python3 &>/dev/null; then
  cd "$AGENT_DIR"
  # Install deps quietly if not already installed
  pip3 install -q psycopg2-binary boto3 2>/dev/null || true
  # Port-forward pgvector for local access during seeding
  kubectl port-forward -n "$NAMESPACE" svc/pgvector 5432:5432 &
  PF_PID=$!
  sleep 3
  python3 seed_runbooks.py
  kill $PF_PID 2>/dev/null || true
  echo "  ✓ Runbooks seeded"
else
  echo "  ⚠  python3 not found — skipping seed. Run manually:"
  echo "     kubectl port-forward -n $NAMESPACE svc/pgvector 5432:5432 &"
  echo "     cd agent && python3 seed_runbooks.py"
fi

# ── Verify ───────────────────────────────────────────────────
echo ""
ROW_COUNT=$(kubectl exec -n "$NAMESPACE" pgvector-0 -- \
  psql -U postgres -d sre_agent -t -c "SELECT COUNT(*) FROM runbook_chunks;" \
  2>/dev/null | tr -d ' ')
echo "  Runbook chunks in DB: ${ROW_COUNT}"

echo ""
echo "═══════════════════════════════════════════════════════"
echo "  ✅  Phase 2 complete"
echo "  pgvector ready at pgvector.$NAMESPACE.svc.cluster.local:5432"
echo "═══════════════════════════════════════════════════════"
