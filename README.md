# SRE-AI-Agent-Observability on AWS

> Chaos Engineering → Automated Root Cause Analysis using LangGraph + Amazon Bedrock on EKS

## Architecture

```
chaoskube (pod killer)
    ↓ pod restarts
Prometheus (kube-prometheus-stack)
    ↓ remote_write
Grafana Cloud Mimir
    ↓ alert rule fires
Webhook → /agent/triage (LangGraph Agent on EKS)
    ↓ 4-node pipeline
    alert_parser → runbook_retriever (pgvector RAG)
                 → diagnoser (Amazon Bedrock Claude)
                 → rca_writer
    ↓ logs RCA to stdout
Promtail → CloudWatch Logs
    ↓
Grafana Dashboard (chaos + RCA panels)
```

## Stack

| Layer | Service |
|---|---|
| Compute | EKS (4× t3.small) |
| Container Registry | Amazon ECR |
| LLM | Amazon Bedrock (Claude 3 Haiku) |
| Vector DB | pgvector (StatefulSet, EBS PVC) |
| Metrics | Prometheus → Grafana Cloud Mimir |
| Logs | Promtail → Amazon CloudWatch Logs |
| Alerting | Grafana Cloud Alert Rules → Webhook |
| Chaos | chaoskube |
| Load Balancer | AWS ALB Controller |
| Secrets | AWS Secrets Manager + K8s Secrets |

## Deployment Phases

| Phase | What | Script |
|---|---|---|
| **Phase 1** | EKS cluster + VPC + ALB + namespaces + IAM (Terraform) | `scripts/infra-up.sh` |
| **Phase 2** | pgvector StatefulSet + EBS PVC + runbook seed | `scripts/deploy-pgvector.sh` |
| **Phase 3** | FastAPI app → ECR → EKS + HPA | `scripts/deploy-app.sh` |
| **Phase 4** | LangGraph agent → ECR → EKS (Bedrock) | `scripts/deploy-agent.sh` |
| **Phase 5** | kube-prometheus-stack + ServiceMonitors + Alert Rules | `scripts/deploy-monitoring.sh` |
| **Phase 6** | Grafana Cloud remote_write + alerts + webhook | `scripts/configure-grafana-cloud.sh` |
| **Phase 7** | chaoskube pod killer | `scripts/deploy-chaoskube.sh` |
| **Phase 8** | Promtail DaemonSet → CloudWatch Logs | `scripts/deploy-promtail-cloudwatch.sh` |
| **Phase 9** | Import Grafana chaos dashboard | `docs/grafana-chaos-dashboard.json` |

## Quick Start

```bash
cp .env.template .env
# fill in all values in .env
source .env
./scripts/infra-up.sh
```

## Documentation

- [Architecture & Security](docs/architecture-security.md)
- [IAM Roles & Policies](docs/iam-roles.md)
- [Runbook: Deployment](docs/runbook-deployment.md)
- [Runbook: Teardown](docs/runbook-teardown.md)

## Region & Account

- Region: `ap-south-1`
- Cluster: `sre-ai-agent-cluster`
