#!/usr/bin/env bash
# =============================================================
# Master Deploy Script — runs all phases in order
#
# Usage:
#   bash scripts/deploy-all.sh             # run all phases
#   bash scripts/deploy-all.sh --from 3    # start from Phase 3
#   bash scripts/deploy-all.sh --only 2    # run only Phase 2
#
# Each phase script is idempotent — safe to re-run.
# =============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

START_PHASE=1
ONLY_PHASE=""

# Parse args
while [[ $# -gt 0 ]]; do
  case "$1" in
    --from) START_PHASE="$2"; shift 2 ;;
    --only) ONLY_PHASE="$2";  shift 2 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

run_phase() {
  local num="$1"
  local name="$2"
  local script="$3"

  # Skip if --only is set and this isn't the target
  [[ -n "$ONLY_PHASE" && "$ONLY_PHASE" != "$num" ]] && return 0
  # Skip if before --from
  [[ "$num" -lt "$START_PHASE" ]] && return 0

  echo ""
  echo "╔═══════════════════════════════════════════════════════╗"
  echo "║  Phase ${num}: ${name}"
  echo "╚═══════════════════════════════════════════════════════╝"
  bash "${SCRIPT_DIR}/${script}"
}

echo "╔═══════════════════════════════════════════════════════╗"
echo "║     SRE-AI-Agent — Full Deployment                    ║"
echo "╚═══════════════════════════════════════════════════════╝"

run_phase 1 "Infrastructure Bootstrap (Terraform + Helm)"  "infra-up.sh"
run_phase 2 "pgvector + Runbook Seed"                      "deploy-pgvector.sh"
run_phase 3 "FastAPI App"                                  "deploy-app.sh"
run_phase 4 "LangGraph Agent (Bedrock)"                    "deploy-agent.sh"
run_phase 5 "Prometheus + Grafana"                         "deploy-monitoring.sh"
run_phase 6 "Grafana Cloud (remote_write + alerts)"        "configure-grafana-cloud.sh"
run_phase 7 "chaoskube"                                    "deploy-chaoskube.sh"
run_phase 8 "Promtail → CloudWatch"                        "deploy-promtail-cloudwatch.sh"

echo ""
echo "╔═══════════════════════════════════════════════════════╗"
echo "║  ✅  All phases complete — chaos-to-RCA loop is live  ║"
echo "╚═══════════════════════════════════════════════════════╝"
echo ""
echo "  Phase 9 (Chaos Dashboard) — manual import:"
echo "  Grafana Cloud → Dashboards → Import → docs/grafana-chaos-dashboard.json"
