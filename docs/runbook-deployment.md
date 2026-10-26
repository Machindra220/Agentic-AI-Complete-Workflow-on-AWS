# Deployment Runbook

## Prerequisites — Install These First

### 1. Terraform

```bash
# Windows (PowerShell, run as Admin)
winget install -e --id Hashicorp.Terraform

# Verify
terraform version
# Expected: Terraform v1.6.x or higher
```

### 2. AWS CLI v2

```bash
winget install -e --id Amazon.AWSCLI

# Verify
aws --version
```

### 3. kubectl

```bash
winget install -e --id Kubernetes.kubectl

# Verify
kubectl version --client
```

### 4. Helm

```bash
winget install -e --id Helm.Helm

# Verify
helm version
```

### 5. Docker Desktop

```bash
winget install -e --id Docker.DockerDesktop

# Verify
docker --version
```

### 6. Configure AWS CLI

```bash
aws configure
# AWS Access Key ID     : <your access key>
# AWS Secret Access Key : <your secret key>
# Default region name   : ap-south-1
# Default output format : json

# Verify — should print your account ID
aws sts get-caller-identity
```

---

## Phase 1 — Infrastructure Bootstrap (Terraform)

**Time:** ~20 minutes (EKS cluster takes ~15 min to create)

### Step 1 — Fill in your variables

```bash
cd D:\Projects\Agentic-AI-on-AWS\terraform

# Copy the template
copy terraform.tfvars.template terraform.tfvars

# Open terraform.tfvars in any text editor and set:
#   aws_account_id = "YOUR_12_DIGIT_ACCOUNT_ID"
# (everything else has sensible defaults)
```

### Step 2 — Run infra-up

```bash
cd D:\Projects\Agentic-AI-on-AWS
bash scripts/infra-up.sh
```

The script will:
1. Run `terraform init` (downloads AWS, EKS, Kubernetes providers)
2. Run `terraform plan` (shows you exactly what will be created — review it!)
3. Ask for confirmation before applying
4. Run `terraform apply` (~15 min)
5. Update your `~/.kube/config` automatically
6. Print all output values you'll need for later phases

### Step 3 — Verify

```bash
# 4 nodes should be Ready
kubectl get nodes

# Expected output:
# NAME                                        STATUS   ROLES    AGE
# ip-10-0-1-xx.ap-south-1.compute.internal   Ready    <none>   2m
# ip-10-0-1-xx.ap-south-1.compute.internal   Ready    <none>   2m
# ip-10-0-1-xx.ap-south-1.compute.internal   Ready    <none>   2m   ← app-nodes (×3)
# ip-10-0-2-xx.ap-south-1.compute.internal   Ready    <none>   2m   ← agent-nodes (×1)

# 4 namespaces
kubectl get namespaces | grep -E 'sre-ai-agent|monitoring|chaos'

# 2 ECR repos
aws ecr describe-repositories --region ap-south-1 \
  --query 'repositories[*].repositoryName' --output table

# ALB controller running
kubectl get pods -n kube-system | grep aws-load-balancer
```

### Step 4 — Save Terraform outputs

```bash
cd terraform
terraform output
```

**Copy and save these values** — they are used automatically by deploy scripts:
- `ecr_app_url` — used by `deploy-app.sh` for ECR push
- `ecr_agent_url` — used by `deploy-agent.sh` for ECR push
- `sre_agent_role_arn` — injected into `k8s/agent/serviceaccount.yaml` by `deploy-agent.sh`
- `promtail_role_arn` — injected into `k8s/promtail/serviceaccount.yaml` by `deploy-promtail-cloudwatch.sh` (Phase 8)
- `update_kubeconfig_command` — run this any time you switch machines

---

## Phase 2 — pgvector + Runbook Seeding

```bash
bash scripts/deploy-pgvector.sh
```

**Verify:**
```bash
kubectl get pods -n sre-ai-agent-llm
# pgvector-0   Running

kubectl exec -n sre-ai-agent-llm pgvector-0 -- \
  psql -U postgres -d sre_agent -c "SELECT COUNT(*) FROM runbook_chunks;"
# Expected: count = 17
```

---

## Phase 3 — FastAPI App

```bash
# Get ECR URL from terraform output
ECR_APP=$(cd terraform && terraform output -raw ecr_app_url)

bash scripts/deploy-app.sh
```

**Verify:**
```bash
kubectl get pods -n sre-ai-agent
# sre-demo-app-xxx   1/1 Running  (×2)

APP_LB=$(kubectl get svc sre-demo-api -n sre-ai-agent \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
curl http://${APP_LB}/api/health
# {"status":"healthy","service":"sre-ai-agent-app","version":"1.0.0"}
```

---

## Phase 4 — LangGraph Agent (Bedrock)

> **Before deploying:** ensure Bedrock model access is enabled in AWS Console →
> Amazon Bedrock → Model access → ap-south-1:
> - Claude 3.5 Sonnet (`anthropic.claude-3-5-sonnet-20241022-v2:0`) ✅
> - Titan Embeddings V2 (`amazon.titan-embed-text-v2:0`) ✅

```bash
# Sync latest IAM policy (Bedrock model ARNs)
cd terraform && terraform apply -auto-approve && cd ..

bash scripts/deploy-agent.sh
```

**Verify:**
```bash
kubectl get pods -n sre-ai-agent-llm
# pgvector-0    1/1 Running
# sre-agent-xxx 1/1 Running

kubectl port-forward -n sre-ai-agent-llm svc/sre-agent 18081:8081 &

curl http://localhost:18081/agent/health
# {"status":"healthy","service":"sre-ai-agent","version":"1.0.0","rca_store_count":0}

curl -s -X POST http://localhost:18081/agent/triage \
  -H "Content-Type: application/json" \
  -d '{
    "alert_name": "High Error Rate",
    "severity": "P2",
    "service": "sre-demo-api",
    "message": "5xx errors spiking in last 5 minutes"
  }' | python -m json.tool
# Expected: confidence_score > 0.6, runbook_used populated, status: completed
```

---

## Phase 5 — Prometheus + Grafana

```bash
bash scripts/deploy-monitoring.sh
```

**Verify:**
```bash
kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80
# Open http://localhost:3000
# Login: admin / prom-operator
```

---

## Phase 6 — Grafana Cloud (remote_write + alerts)

```bash
# Set your Grafana Cloud values in .env first, then:
bash scripts/configure-grafana-cloud.sh
```

---

## Phase 7 — chaoskube

```bash
bash scripts/deploy-chaoskube.sh
```

**Verify:**
```bash
kubectl logs -n chaos deployment/chaoskube --tail=20
# "killing pod sre-ai-agent/..."
```

---

## Phase 8 — Promtail → CloudWatch

```bash
bash scripts/deploy-promtail-cloudwatch.sh
```

**Verify:**
```bash
aws logs describe-log-groups \
  --log-group-name-prefix /sre-ai-agent \
  --region ap-south-1
```

---

## Phase 9 — Import Chaos Dashboard

1. Open your Grafana Cloud dashboard
2. Go to **Dashboards → Import**
3. Upload `docs/grafana-chaos-dashboard.json`
4. Bind datasources:
   - `DS_PROMETHEUS` → your Grafana Cloud Prometheus
   - `DS_CLOUDWATCH` → CloudWatch (region: ap-south-1, auth: workspace IAM role)
5. Set auto-refresh to **30s**

---

## Full Loop Smoke Test

```bash
# 1. Confirm chaos is killing pods
kubectl logs -n chaos deployment/chaoskube -f

# 2. Watch agent pick up the alert
kubectl logs -n sre-ai-agent-llm deployment/sre-agent -f

# 3. Check CloudWatch for RCA output
aws logs tail /sre-ai-agent/k8s --follow --region ap-south-1
```

---

## Useful kubectl shortcuts

```bash
# All pods across project namespaces
kubectl get pods -A -l project=sre-ai-agent

# Stream all agent logs
kubectl logs -n sre-ai-agent-llm -l app=sre-agent -f

# Check HPA for FastAPI
kubectl get hpa -n sre-ai-agent

# Check node resource usage
kubectl top nodes
kubectl top pods -A
```
