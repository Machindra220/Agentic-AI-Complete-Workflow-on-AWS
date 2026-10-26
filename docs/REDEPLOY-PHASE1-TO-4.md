# SRE AI Agent — Full Redeploy Guide (Phase 1 → Phase 4)

> **Purpose:** Complete instructions to rebuild the entire project from zero after
> `infra-down.sh` has destroyed all AWS resources.
>
> **Region:** `ap-south-1` (Mumbai)
> **Cluster:** `sre-ai-agent-cluster`
> **LLM:** Amazon Bedrock `anthropic.claude-3-5-sonnet-20241022-v2:0`
> **Last updated:** 2026-10-26

---

## Pre-flight checklist

Before running any script, confirm the following:

| Check | Command | Expected |
|---|---|---|
| AWS CLI authenticated | `aws sts get-caller-identity` | Shows your account ID |
| Correct account | `aws sts get-caller-identity --query Account --output text` | Must match `.env` `AWS_ACCOUNT_ID` |
| kubectl available | `kubectl version --client` | v1.28+ |
| Terraform available | `terraform version` | v1.5+ |
| Helm available | `helm version` | v3.x |
| Docker running | `docker info` | No errors |
| Git Bash / WSL | All scripts use `bash` | Use Git Bash on Windows |

---

## Step 0 — Environment setup

### 0.1 Copy and fill `.env`

```bash
cp .env.template .env
```

Edit `.env` — fill every `<placeholder>`:

```bash
AWS_ACCOUNT_ID=<your-12-digit-account-id>    # aws sts get-caller-identity --query Account --output text
AWS_REGION=ap-south-1
CLUSTER_NAME=sre-ai-agent-cluster
BEDROCK_MODEL_ID=anthropic.claude-3-5-sonnet-20241022-v2:0
PG_PASSWORD=<choose-a-strong-password>        # any strong password, only used inside cluster
GRAFANA_CLOUD_API_KEY=<glc_...>               # from grafana.com stack settings (Phase 6 only)
GRAFANA_CLOUD_PROMETHEUS_URL=<url>            # from grafana.com stack settings (Phase 6 only)
GRAFANA_CLOUD_PROMETHEUS_USER=<numeric-id>    # from grafana.com stack settings (Phase 6 only)
```

> **CRITICAL:** `AWS_ACCOUNT_ID` must exactly match the account your AWS CLI is authenticated to.
> A mismatch causes ECR push 403 errors and cross-account IAM failures.

### 0.2 Fill `terraform/terraform.tfvars`

```bash
cp terraform/terraform.tfvars.template terraform/terraform.tfvars
```

Edit `terraform.tfvars`:
```hcl
aws_account_id = "<same-12-digit-id-as-.env>"
aws_region     = "ap-south-1"
cluster_name   = "sre-ai-agent-cluster"
```

### 0.3 Enable Bedrock model access

1. AWS Console → **Amazon Bedrock** → **Model access** (ensure region = ap-south-1)
2. Click **Manage model access**
3. Enable:
   - **Claude 3.5 Sonnet** (`anthropic.claude-3-5-sonnet-20241022-v2:0`) ← primary LLM
   - **Titan Embeddings V2** (`amazon.titan-embed-text-v2:0`) ← for runbook RAG
4. Click **Save changes** — wait 1–2 minutes for status to show **Access granted**

---

## Phase 1 — AWS Infrastructure (VPC + EKS + IAM + ECR)

**Script:** `scripts/infra-up.sh`

```bash
source .env
bash scripts/infra-up.sh
```

**What it does:**
- Runs `terraform init` + `terraform apply` in `terraform/`
- Creates: VPC (3 AZs), EKS 1.32 cluster, 2 node groups (app-nodes + agent-nodes), IAM IRSA roles, ECR repos, CloudWatch log group
- Installs ALB Controller via Helm + IRSA
- Updates `~/.kube/config` for the new cluster

**Expected duration:** ~15 minutes

**Verify:**
```bash
kubectl get nodes
# Should show 4 nodes: 3 app-nodes + 1 agent-node, all Ready

kubectl get pods -n kube-system | grep aws-load-balancer
# Should show: aws-load-balancer-controller-... 2/2 Running
```

**Common issues:**
- `AWS_ACCOUNT_ID mismatch` → re-check `.env` vs `aws sts get-caller-identity`
- ALB controller `elasticloadbalancing:AddTags` AccessDenied → IAM policy already includes the fix; just re-run `terraform apply`
- Nodes not Ready after 5 min → check `kubectl describe node <name>` for taints/events

---

## Phase 2 — Namespaces + pgvector

**Script:** `scripts/deploy-pgvector.sh`

```bash
source .env
bash scripts/deploy-pgvector.sh
```

**What it does:**
- Creates namespaces: `sre-ai-agent`, `sre-ai-agent-llm`, `monitoring`, `chaos`
- Deploys pgvector StatefulSet (PostgreSQL 16 + pgvector extension) with 10Gi EBS PVC
- Creates `pgvector-secret` from `PG_PASSWORD` in `.env`
- Seeds 4 runbooks → 17 chunks into the `runbook_chunks` table (Bedrock Titan Embeddings V2, 1024-dim)

**Expected duration:** ~3 minutes

**Verify:**
```bash
kubectl get pods -n sre-ai-agent-llm
# pgvector-0   1/1 Running

kubectl exec -n sre-ai-agent-llm pgvector-0 -- \
  psql -U postgres -d sre_agent -c "SELECT COUNT(*) FROM runbook_chunks;"
# Should return: count = 17
```

**Common issues:**
- Seed job fails → pgvector pod may not be fully Ready; wait 30s and re-run `bash scripts/deploy-pgvector.sh`
- EBS volume binding Pending → node group may be in wrong AZ; check `kubectl describe pvc pgvector-pvc -n sre-ai-agent-llm`

---

## Phase 3 — FastAPI App (sre-demo-api)

**Script:** `scripts/deploy-app.sh`

```bash
source .env
bash scripts/deploy-app.sh
```

**What it does:**
- Builds `app/Dockerfile` for `linux/amd64`
- Pushes to ECR `sre-ai-agent-app`
- Deploys to `sre-ai-agent` namespace (2 replicas, app-nodes)
- Creates NLB LoadBalancer service via ALB Controller

**Expected duration:** ~5 minutes (Docker build + push)

**Verify:**
```bash
kubectl get pods -n sre-ai-agent
# sre-demo-app-xxx   1/1 Running  (×2)

kubectl get svc -n sre-ai-agent
# EXTERNAL-IP column shows an AWS hostname (takes 2-3 min to provision)
```

**Test the app:**
```bash
# Get the LB hostname
LB=$(kubectl get svc sre-demo-app -n sre-ai-agent \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

curl http://$LB/api/health
# {"status":"healthy","service":"sre-ai-agent-app","version":"1.0.0"}

curl http://$LB/api/products
# Returns list of dummy products
```

**Common issues:**
- LB EXTERNAL-IP stuck Pending after 5 min → check ALB controller logs:
  ```bash
  kubectl logs -n kube-system deployment/aws-load-balancer-controller | tail -30
  ```
  Most likely cause: IAM permission; `terraform apply` to sync policy.

---

## Phase 4 — LangGraph AI Agent

### 4.1 Apply updated IAM first

```bash
cd terraform && terraform apply -auto-approve && cd ..
```

This ensures the Bedrock IAM policy includes the Sonnet model ARN.

### 4.2 Verify Bedrock model enabled (see Step 0.3 above)

### 4.3 Deploy the agent

**Script:** `scripts/deploy-agent.sh`

```bash
source .env
bash scripts/deploy-agent.sh
```

**What it does:**
- Pre-flight: checks kubectl connected + pgvector-secret exists
- Reads IRSA role ARN from `terraform output sre_agent_role_arn`
- Builds `agent/Dockerfile` (from repo root)
- Pushes to ECR `sre-ai-agent-llm`
- Injects IRSA ARN via `sed` into `k8s/agent/serviceaccount.yaml`
- Deploys to `sre-ai-agent-llm` namespace (1 replica, agent-node with NoSchedule taint)
- Port-forwards to `localhost:18081` and prints health check result

**Expected duration:** ~5 minutes

**Verify:**
```bash
kubectl get pods -n sre-ai-agent-llm
# pgvector-0      1/1 Running
# sre-agent-xxx   1/1 Running

kubectl port-forward -n sre-ai-agent-llm svc/sre-agent 18081:8081 &

curl http://localhost:18081/agent/health
# {"status":"healthy","service":"sre-ai-agent","version":"1.0.0","rca_store_count":0}
```

### 4.4 Run end-to-end triage test

```bash
curl -s -X POST http://localhost:18081/agent/triage \
  -H "Content-Type: application/json" \
  -d '{
    "alert_name": "High Error Rate",
    "severity": "P2",
    "service": "sre-demo-api",
    "message": "5xx errors spiking in last 5 minutes"
  }' | python -m json.tool
```

**Expected (healthy) response:**
```json
{
  "incident_id": "INC-20261026-XXXXXX",
  "status": "completed",
  "confidence_score": 0.82,
  "runbook_used": "high-error-rate-runbook.md",
  "rca_url": "/agent/rca/INC-.../html",
  "processing_time_seconds": 4.2
}
```

Key fields to verify:
- `confidence_score` > 0.6 ✅ (LLM diagnosis succeeded)
- `runbook_used` ≠ `"none"` ✅ (RAG retrieval succeeded)
- `status` = `"completed"` ✅

**View the RCA HTML page:**
```bash
# Open in browser:
# http://localhost:18081/agent/rca/<incident_id>/html
```

**View the incident dashboard:**
```bash
# Open in browser:
# http://localhost:18081/agent/dashboard
# Agent URL auto-fills — click Connect
```

**Common issues:**

| Error | Cause | Fix |
|---|---|---|
| `ValidationException: model identifier is invalid` | Wrong model ID or model not in region | Verify `BEDROCK_MODEL_ID=anthropic.claude-3-5-sonnet-20241022-v2:0` in deployment.yaml and model access enabled |
| `ResourceNotFoundException: Access denied (Legacy)` | Old model ID still in pod | Redeploy: `bash scripts/deploy-agent.sh` |
| `runbook_used: none` | pgvector not seeded or Titan Embeddings not enabled | Re-run `bash scripts/deploy-pgvector.sh`; check Titan embed model access |
| Port 18081 in use | Previous port-forward still running | `kill $(lsof -ti:18081)` or use port 19081 |
| Agent pod `0/1` | IRSA role not found or pgvector-secret missing | Check `kubectl describe pod -n sre-ai-agent-llm <pod-name>` |

---

## Architecture summary (Phase 4 state)

```
Internet
    │
    ▼
AWS NLB (ALB Controller)
    │
    ▼
sre-demo-app (FastAPI, port 8080)     ← namespace: sre-ai-agent
    │                                    node group: app-nodes
    │  alert POST /agent/triage
    ▼
sre-agent (LangGraph, port 8081)      ← namespace: sre-ai-agent-llm
    │                                    node group: agent-nodes (NoSchedule taint)
    │                                    IRSA → Bedrock (no static keys)
    ├── alert_parser   (Node 1)
    ├── runbook_retriever (Node 2) ──→ pgvector (StatefulSet, 10Gi EBS)
    │                                    Titan Embed V2 (1024-dim cosine sim)
    ├── diagnoser      (Node 3) ──────→ Bedrock Claude 3.5 Sonnet
    │   └── retry if confidence < 0.60 (max 2 retries)
    └── rca_writer     (Node 4) → RCA markdown → HTML
```

---

## Quick reference — all scripts

| Script | Phase | What it does |
|---|---|---|
| `scripts/infra-up.sh` | 1 | Terraform + ALB Controller install |
| `scripts/deploy-pgvector.sh` | 2 | Namespaces + pgvector + runbook seeding |
| `scripts/deploy-app.sh` | 3 | FastAPI app → ECR → EKS |
| `scripts/deploy-agent.sh` | 4 | LangGraph agent → ECR → EKS |
| `scripts/infra-down.sh` | teardown | Destroys ALL resources (safe order) |

---

## Notes

- All scripts source `.env` — always run `source .env` before executing any script
- IRSA is used for all AWS access — no static AWS keys are ever stored in K8s secrets
- pgvector password is stored only in `pgvector-secret` (K8s Secret in `sre-ai-agent-llm` ns)
- The agent pod runs on the `agent-nodes` node group with a `workload=ai-agent:NoSchedule` taint — only the agent pod tolerates it
- Docker images are built for `linux/amd64` (explicitly) to avoid ARM incompatibility on M1/M2 Macs or Windows ARM
