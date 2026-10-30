# Troubleshooting Guide & Helpful Commands

> Running log of all errors encountered, root causes, and fixes.
> Updated as new issues are found.
> Last updated: 2026-10-30

---

## Quick Reference — Useful Commands

```bash
# Update kubeconfig for the cluster
aws eks update-kubeconfig --region ap-south-1 --name sre-ai-agent-cluster

# Check all pods across project namespaces
kubectl get pods -n sre-ai-agent
kubectl get pods -n sre-ai-agent-llm
kubectl get pods -n kube-system | grep aws-load-balancer

# Stream agent logs
kubectl logs -n sre-ai-agent-llm -l app=sre-agent -f

# Port-forward agent (kill existing first if needed)
powershell -Command "Stop-Process -Id (Get-NetTCPConnection -LocalPort 18081).OwningProcess -Force" 2>/dev/null || true
kubectl port-forward -n sre-ai-agent-llm svc/sre-agent 18081:8081 &

# End-to-end triage test
curl -s -X POST http://localhost:18081/agent/triage \
  -H "Content-Type: application/json" \
  -d '{"alert_name":"High Error Rate","severity":"P2","service":"sre-demo-api","message":"5xx errors spiking in last 5 minutes"}' \
  | python -m json.tool

# Check IAM policy attached to agent role
aws iam list-attached-role-policies --role-name sre-ai-agent-cluster-sre-agent

# Check current Bedrock policy content
aws iam get-policy-version \
  --policy-arn arn:aws:iam::893483579480:policy/sre-ai-agent-cluster-bedrock-invoke \
  --version-id $(aws iam get-policy \
    --policy-arn arn:aws:iam::893483579480:policy/sre-ai-agent-cluster-bedrock-invoke \
    --query 'Policy.DefaultVersionId' --output text) \
  --query 'PolicyVersion.Document' --output json

# Force-delete stuck port (Windows)
powershell -Command "Stop-Process -Id (Get-NetTCPConnection -LocalPort 18081).OwningProcess -Force"

# Find and delete leftover NLBs blocking VPC deletion
aws elbv2 describe-load-balancers --region ap-south-1 \
  --query 'LoadBalancers[*].[LoadBalancerArn,DNSName,State.Code]' --output table

# Find leftover security groups in a VPC
aws ec2 describe-security-groups --region ap-south-1 \
  --filters "Name=vpc-id,Values=<vpc-id>" \
  --query 'SecurityGroups[*].[GroupId,GroupName]' --output table

# Check EKS access entries
aws eks list-access-entries --cluster-name sre-ai-agent-cluster --region ap-south-1

# Verify pgvector runbook chunks
kubectl exec -n sre-ai-agent-llm pgvector-0 -- \
  psql -U postgres -d sre_agent -c "SELECT COUNT(*) FROM runbook_chunks;"
```

---

## Issues & Fixes

---

### 1. AWS_ACCOUNT_ID mismatch — ECR push 403

**Error:**
```
denied: Your authorization token has expired. Reload your credentials and try again
# or
Error: 403 Forbidden on ECR push
```

**Cause:** `.env` had a different `AWS_ACCOUNT_ID` than the authenticated IAM user's account.

**Fix:**
```bash
# Get the correct account ID
aws sts get-caller-identity --query Account --output text

# Update .env
AWS_ACCOUNT_ID=<correct-12-digit-id>
```

**Prevention:** `infra-up.sh` now validates `AWS_ACCOUNT_ID` at pre-flight and exits if it mismatches.

---

### 2. ALB Controller — `elasticloadbalancing:AddTags` AccessDenied

**Error:**
```
AccessDenied: User is not authorized to perform elasticloadbalancing:AddTags
on resource arn:aws:elasticloadbalancing:...:targetgroup/...
```

**Cause:** The ALB Controller IAM policy had `AddTags` conditioned on the resource already having a cluster tag — but brand-new target groups don't have that tag yet.

**Fix:** Added a second `AddTags` statement in `iam/alb-controller-policy.json` with `CreateAction` condition:
```json
{
  "Effect": "Allow",
  "Action": ["elasticloadbalancing:AddTags"],
  "Resource": ["arn:aws:elasticloadbalancing:*:*:targetgroup/*/*", ...],
  "Condition": {
    "StringEquals": {
      "elasticloadbalancing:CreateAction": ["CreateTargetGroup", "CreateLoadBalancer"]
    }
  }
}
```
Then `terraform apply` + `kubectl rollout restart deployment/aws-load-balancer-controller -n kube-system`.

---

### 3. Bedrock `ResourceNotFoundException` — model marked Legacy

**Error:**
```
ResourceNotFoundException: Access denied. This Model is marked by provider as Legacy
```

**Cause:** `anthropic.claude-3-haiku-20240307-v1:0` was blocked after 30 days of inactivity (AWS Legacy model policy).

**Fix:** Upgraded to `anthropic.claude-3-5-sonnet-20241022-v2:0` across:
- `agent/nodes/diagnoser.py`
- `k8s/agent/deployment.yaml`
- `terraform/variables.tf`
- `.env.template`

---

### 4. Bedrock `ValidationException` — model identifier invalid

**Error:**
```
ValidationException: The provided model identifier is invalid
```

**Cause:** `anthropic.claude-3-5-haiku-20241022-v1:0` does not exist as a direct model in `ap-south-1` (Mumbai). It is only available via cross-region inference in that region.

**Fix:** Switched to `anthropic.claude-3-5-sonnet-20241022-v2:0` which is confirmed available in `ap-south-1`.

---

### 5. Bedrock `AccessDeniedException` — IAM policy has wrong model ARN

**Error:**
```
AccessDeniedException: User: arn:aws:sts::...:assumed-role/sre-ai-agent-cluster-sre-agent/...
is not authorized to perform: bedrock:InvokeModel on resource:
arn:aws:bedrock:ap-south-1::foundation-model/anthropic.claude-3-5-sonnet-20241022-v2:0
because no identity-based policy allows the bedrock:InvokeModel action
```

**Cause:** Terraform state drift — the IAM policy in AWS still had the old model ARN (`claude-3-haiku`) even though the code was updated. `terraform apply` did not recreate it because state showed no diff.

**Fix:**
```bash
cd terraform
terraform taint aws_iam_policy.bedrock
terraform apply -auto-approve
kubectl rollout restart deployment/sre-agent -n sre-ai-agent-llm
```

---

### 6. EKS Access Entry 409 — duplicate on re-deploy

**Error:**
```
Error: creating EKS Access Entry: ResourceInUseException:
The specified access entry resource is already in use on this cluster.
```

**Cause:** The EKS Terraform module automatically registers the cluster creator as an access entry. `eks-access.tf` also declares the same IAM user — on a re-run after partial destroy this causes a 409 conflict.

**Fix:** Import the existing entry into Terraform state before apply:
```bash
terraform import aws_eks_access_entry.admin \
  "sre-ai-agent-cluster:arn:aws:iam::893483579480:user/Machindra"
terraform apply -auto-approve
```

**Prevention:** `infra-up.sh` now auto-imports the access entry if it exists in AWS but not in Terraform state.

---

### 7. Terraform Kubernetes provider — `Unauthorized` on fresh cluster

**Error:**
```
Error: Unauthorized
  with kubernetes_namespace.namespaces["sre-ai-agent"]
  on namespaces.tf line 5
```

**Cause:** Terraform initializes the Kubernetes provider at plan time, before the EKS API server is fully ready. Even with `depends_on = [module.eks]`, the provider can't authenticate during the initial apply on a brand-new cluster.

**Fix:** Moved namespace creation out of Terraform (`namespaces.tf` deleted) into `infra-up.sh` using `kubectl create namespace` — runs after `aws eks update-kubeconfig` and node readiness check.

---

### 8. VPC deletion stuck during `terraform destroy`

**Error:**
```
module.vpc.aws_subnet.public[0]: Still destroying... [18m elapsed]
module.vpc.aws_internet_gateway.this[0]: Still destroying... [18m elapsed]
```

**Cause:** AWS NLB (created by the LoadBalancer service) was still attached to the VPC subnets. VPC deletion blocks until all ENIs and load balancers inside it are removed.

**Fix (in a second terminal while destroy is running):**
```bash
# Find stuck NLBs
aws elbv2 describe-load-balancers --region ap-south-1 \
  --query 'LoadBalancers[*].[LoadBalancerArn,State.Code]' --output table

# Delete the NLB
aws elbv2 delete-load-balancer --region ap-south-1 \
  --load-balancer-arn <arn>

# Delete leftover target groups
aws elbv2 describe-target-groups --region ap-south-1 \
  --query 'TargetGroups[*].TargetGroupArn' --output text | \
  tr '\t' '\n' | while read arn; do
    aws elbv2 delete-target-group --region ap-south-1 --target-group-arn "$arn"
  done

# Delete leftover security groups
aws ec2 delete-security-group --region ap-south-1 --group-id <sg-id>
```

**Prevention:** Always run `infra-down.sh` instead of `terraform destroy` directly — it deletes Helm releases and LoadBalancer services in the correct order before destroying infra.

---

### 9. `terraform destroy` — `Unauthorized` on kubernetes_namespace

**Error:**
```
Error: Unauthorized
  with kubernetes_namespace.namespaces["sre-ai-agent"]
```

**Cause:** EKS cluster API server already destroyed, Kubernetes provider can't authenticate to delete namespace resources.

**Fix:** Remove them from Terraform state (they're already gone):
```bash
terraform state rm 'kubernetes_namespace.namespaces["sre-ai-agent"]'
terraform state rm 'kubernetes_namespace.namespaces["sre-ai-agent-llm"]'
terraform state rm 'kubernetes_namespace.namespaces["monitoring"]'
terraform state rm 'kubernetes_namespace.namespaces["chaos"]'
terraform destroy -auto-approve
```

---

### 10. Port 18081 already in use

**Error:**
```
Unable to listen on port 18081: bind: Only one usage of each socket address
```

**Cause:** Previous `kubectl port-forward` still running (often left over from `deploy-agent.sh`).

**Fix (Git Bash):**
```bash
kill $(lsof -ti:18081) 2>/dev/null || true
```

**Fix (Windows — if lsof not available):**
```bash
powershell -Command "Stop-Process -Id (Get-NetTCPConnection -LocalPort 18081).OwningProcess -Force"
```

---

### 11. `runbook_used: none` in triage response

**Symptom:** `"runbook_used": "none"` in triage JSON response.

**Cause:** Runbook retriever was importing from a non-existent module (`from rag.retriever import retrieve`). Also occurs if the diagnoser crashes before completing (the pipeline short-circuits).

**Fix:** Rewrote `agent/nodes/runbook_retriever.py` with direct pgvector + Bedrock Titan Embeddings V2 query. If diagnoser fails with an error, fix that first — the runbook_used field will populate once the full pipeline completes.

---

### 12. Incident dashboard — "Failed to fetch"

**Symptom:** Dashboard loads but shows `Failed to fetch — Check agent URL and ensure CORS is enabled on /agent/history`.

**Cause:** Hardcoded old ALB URL (`us-east-1`) in the Agent URL input field of `agent/static/incident-dashboard.html`.

**Fix:** Cleared the hardcoded value and added auto-populate on boot:
```javascript
(function () {
  const input = document.getElementById('agentUrl');
  if (!input.value) {
    input.value = window.location.origin + '/agent/history';
  }
})();
```

---

### 13. Bedrock IAM policy — state drift after model upgrade

**Symptom:** `terraform apply` reports no changes but AWS policy still has old model ARN.

**Cause:** Terraform state recorded the policy as up-to-date after a previous apply, so subsequent applies see no diff even though the actual AWS policy wasn't updated (happens when apply partially failed or was interrupted).

**Fix:**
```bash
cd terraform
terraform taint aws_iam_policy.bedrock
terraform apply -auto-approve
```

---

## Teardown Issues

### Teardown stopped early — infra-down.sh timed out on svc deletion

**Symptom:** `error: timed out waiting for the condition on services/sre-demo-api` — script exits at step 2, steps 3-5 never run.

**Cause:** `set -euo pipefail` causes the script to exit on the timeout error.

**Recovery — run manually in order:**
```bash
# 1. Force-delete stuck service
kubectl delete svc sre-demo-api -n sre-ai-agent --grace-period=0 --force

# 2. Delete PVCs
kubectl delete pvc --all -n sre-ai-agent-llm --wait=true --timeout=120s
kubectl delete pvc --all -n sre-ai-agent --wait=true --timeout=120s
sleep 20

# 3. Delete namespaces
kubectl delete namespace sre-ai-agent sre-ai-agent-llm monitoring chaos \
  --wait=true --timeout=120s

# 4. Terraform destroy
cd terraform && terraform destroy -auto-approve
```

---

## Bedrock Model Reference (ap-south-1)

| Model | ID | Available in ap-south-1 |
|---|---|---|
| Claude 3 Haiku | `anthropic.claude-3-haiku-20240307-v1:0` | ✅ but **Legacy** (blocked) |
| Claude 3.5 Haiku | `anthropic.claude-3-5-haiku-20241022-v1:0` | ❌ Not directly available |
| Claude 3.5 Sonnet | `anthropic.claude-3-5-sonnet-20241022-v2:0` | ✅ **Use this** |
| Titan Embed V2 | `amazon.titan-embed-text-v2:0` | ✅ |

> Always enable models in AWS Console → Amazon Bedrock → Model access → ap-south-1 before deploying.
