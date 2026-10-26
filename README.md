# SRE-AI-Agent-Observability on AWS

> Chaos Engineering → Automated Root Cause Analysis using LangGraph + Amazon Bedrock on EKS

## Current Status

| Phase | Description | Status |
|---|---|---|
| **Phase 1** | EKS + VPC + ALB + IAM (Terraform) | ✅ Complete |
| **Phase 2** | pgvector StatefulSet + runbook seeding (17 chunks) | ✅ Complete |
| **Phase 3** | FastAPI demo app → ECR → EKS + NLB + HPA | ✅ Complete |
| **Phase 4** | LangGraph AI Agent → ECR → EKS (Bedrock IRSA) | ✅ Complete |
| **Phase 5** | kube-prometheus-stack + ServiceMonitors + Alert Rules | 🔜 Next |
| **Phase 6** | Grafana Cloud remote_write + alerts + webhook | ⏳ Pending |
| **Phase 7** | chaoskube pod killer | ⏳ Pending |
| **Phase 8** | Promtail DaemonSet → CloudWatch Logs | ⏳ Pending |
| **Phase 9** | Import Grafana chaos dashboard | ⏳ Pending |

---

## Architecture

```
Internet
    │
    ▼
AWS NLB (ALB Controller)
    │
    ├─── sre-demo-app (FastAPI :8080)        ns: sre-ai-agent   / node: app-nodes
    │         POST /agent/triage
    │
    └─── sre-agent (LangGraph :8081)         ns: sre-ai-agent-llm / node: agent-nodes
              │   IRSA → Bedrock (no static keys)
              ├── Node 1: alert_parser
              ├── Node 2: runbook_retriever ──→ pgvector (StatefulSet, 10Gi EBS)
              │                                  Titan Embed V2 (1024-dim cosine)
              ├── Node 3: diagnoser ──────────→ Bedrock Claude 3.5 Sonnet
              │           retry if confidence < 0.60  (max 2 retries)
              └── Node 4: rca_writer → RCA markdown → HTML

[Phase 5+]
Prometheus (kube-prometheus-stack)
    └─ remote_write → Grafana Cloud Mimir
         └─ alert rule fires → POST /agent/triage

[Phase 8+]
Promtail DaemonSet → CloudWatch Logs /sre-ai-agent/k8s
    └─ Grafana Dashboard (CloudWatch datasource)

[Phase 7]
chaoskube → kills pods → triggers Prometheus alert → agent pipeline
```

---

## Stack

| Layer | Service | Detail |
|---|---|---|
| Compute | EKS 1.32 | 4× t3.small (3 app-nodes + 1 agent-node) |
| Container Registry | Amazon ECR | `sre-ai-agent-app`, `sre-ai-agent-llm` |
| LLM | Amazon Bedrock | `anthropic.claude-3-5-sonnet-20241022-v2:0` |
| Embeddings | Amazon Bedrock | `amazon.titan-embed-text-v2:0` (1024-dim) |
| Vector DB | pgvector | PostgreSQL 16 + pgvector, StatefulSet, 10Gi EBS |
| Metrics | Prometheus → Grafana Cloud Mimir | Phase 5/6 |
| Logs | Promtail → Amazon CloudWatch Logs | Phase 8 |
| Alerting | Grafana Cloud Alert Rules → Webhook | Phase 6 |
| Chaos | chaoskube | Phase 7 |
| Load Balancer | AWS NLB via ALB Controller | IRSA, no static credentials |
| Auth | IRSA (IAM Roles for Service Accounts) | Zero static AWS keys in cluster |

---

## Deployment Phases

| Phase | What | Script |
|---|---|---|
| **Phase 1** | EKS cluster + VPC + NLB + namespaces + IAM (Terraform) | `scripts/infra-up.sh` |
| **Phase 2** | pgvector StatefulSet + EBS PVC + runbook seed (17 chunks) | `scripts/deploy-pgvector.sh` |
| **Phase 3** | FastAPI app → ECR → EKS + HPA | `scripts/deploy-app.sh` |
| **Phase 4** | LangGraph agent → ECR → EKS (Bedrock IRSA) | `scripts/deploy-agent.sh` |
| **Phase 5** | kube-prometheus-stack + ServiceMonitors + Alert Rules | `scripts/deploy-monitoring.sh` |
| **Phase 6** | Grafana Cloud remote_write + alerts + webhook | `scripts/configure-grafana-cloud.sh` |
| **Phase 7** | chaoskube pod killer | `scripts/deploy-chaoskube.sh` |
| **Phase 8** | Promtail DaemonSet → CloudWatch Logs | `scripts/deploy-promtail-cloudwatch.sh` |
| **Phase 9** | Import Grafana chaos dashboard | `docs/grafana-chaos-dashboard.json` |

---

## Quick Start

```bash
# 1. Copy and fill environment variables
cp .env.template .env
# Edit .env — set AWS_ACCOUNT_ID, PG_PASSWORD, Grafana Cloud values

# 2. Load env
source .env

# 3. Run phases in order
bash scripts/infra-up.sh          # Phase 1 (~15 min)
bash scripts/deploy-pgvector.sh   # Phase 2 (~3 min)
bash scripts/deploy-app.sh        # Phase 3 (~5 min)
cd terraform && terraform apply -auto-approve && cd ..
bash scripts/deploy-agent.sh      # Phase 4 (~5 min)
```

> Full step-by-step instructions (including verify commands and common issue fixes):
> **[docs/REDEPLOY-PHASE1-TO-4.md](docs/REDEPLOY-PHASE1-TO-4.md)**

---

## Phase 4 — End-to-End Test

```bash
kubectl port-forward -n sre-ai-agent-llm svc/sre-agent 18081:8081 &

curl -s -X POST http://localhost:18081/agent/triage \
  -H "Content-Type: application/json" \
  -d '{
    "alert_name": "High Error Rate",
    "severity": "P2",
    "service": "sre-demo-api",
    "message": "5xx errors spiking in last 5 minutes"
  }' | python -m json.tool
```

Expected: `confidence_score > 0.6`, `runbook_used` populated, `status: completed`.

View RCA: `http://localhost:18081/agent/rca/<incident_id>/html`
View dashboard: `http://localhost:18081/agent/dashboard`

---

## Teardown (stop billing)

```bash
bash scripts/infra-down.sh
```

Destroys in safe order: Helm releases → NLB services → PVCs (EBS) → Namespaces → `terraform destroy`. Takes ~12 minutes.

---

## Documentation

| Doc | Purpose |
|---|---|
| [docs/REDEPLOY-PHASE1-TO-4.md](docs/REDEPLOY-PHASE1-TO-4.md) | Full redeploy guide from zero |
| [docs/architecture-security.md](docs/architecture-security.md) | Security design, IRSA, network policy |
| [docs/runbook-deployment.md](docs/runbook-deployment.md) | Phase-by-phase deployment runbook |
| [docs/runbook-teardown.md](docs/runbook-teardown.md) | Teardown runbook |

---

## Region & Account

- Region: `ap-south-1` (Mumbai)
- Cluster: `sre-ai-agent-cluster`
- EKS: 1.32
- Bedrock model: `anthropic.claude-3-5-sonnet-20241022-v2:0`
