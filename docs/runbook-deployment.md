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

## Phase 22-A — Infrastructure Bootstrap (Terraform)

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

**Copy and save these values** — you'll need them for later phases:
- `ecr_app_url` — for `docker push` in Phase 22-C
- `ecr_agent_url` — for `docker push` in Phase 22-D
- `sre_agent_role_arn` — annotate the K8s service account in Phase 22-D
- `promtail_role_arn` — annotate the K8s service account in Phase 24-B
- `update_kubeconfig_command` — run this any time you switch machines

---

## Phase 22-B — pgvector + Runbook Seeding

```bash
bash scripts/deploy-pgvector.sh
```

**Verify:**
```bash
kubectl get pods -n sre-ai-agent-llm
# pgvector-0   Running

kubectl exec -n sre-ai-agent-llm pgvector-0 -- \
  psql -U postgres -c "SELECT COUNT(*) FROM runbook_chunks;"
```

---

## Phase 22-C — FastAPI App

```bash
# Get ECR URL from terraform output
ECR_APP=$(cd terraform && terraform output -raw ecr_app_url)

bash scripts/deploy-app.sh
```

**Verify:**
```bash
kubectl get pods -n sre-ai-agent
# 3 pods Running

APP_LB=$(kubectl get svc -n sre-ai-agent sre-ai-agent-svc \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
curl http://${APP_LB}/health
# {"status": "ok"}
```

---

## Phase 22-D — LangGraph Agent (Bedrock)

```bash
bash scripts/deploy-agent.sh
```

**Verify:**
```bash
AGENT_LB=$(kubectl get svc -n sre-ai-agent-llm sre-agent-svc \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

curl -X POST http://${AGENT_LB}/agent/triage \
  -H "Content-Type: application/json" \
  -d '{"alerts": [{"labels": {"alertname": "PodRestartRateHigh", "namespace": "sre-ai-agent"}}]}'
# Returns JSON with "rca" field
```

---

## Phase 22-E — Prometheus + Grafana

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

## Phase 23 — Grafana Cloud (remote_write + alerts)

```bash
# Set your Grafana Cloud values in .env first, then:
bash scripts/configure-grafana-cloud.sh
```

---

## Phase 24-A — chaoskube

```bash
bash scripts/deploy-chaoskube.sh
```

**Verify:**
```bash
kubectl logs -n chaos deployment/chaoskube --tail=20
# "killing pod sre-ai-agent/..."
```

---

## Phase 24-B — Promtail → CloudWatch

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

## Phase 24-C — Import Chaos Dashboard

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
