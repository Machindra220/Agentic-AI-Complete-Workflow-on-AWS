# Teardown Runbook

> **Run this when you are done developing** — EKS + EC2 charges accumulate every hour.

## Quick Teardown (saves money)

```bash
source .env
bash scripts/infra-down.sh
```

## Manual Teardown (step by step)

### 1. Helm uninstalls

```bash
helm uninstall chaoskube -n chaos
helm uninstall promtail -n monitoring
helm uninstall kube-prometheus-stack -n monitoring
helm uninstall aws-load-balancer-controller -n kube-system
```

### 2. Delete PVCs (releases EBS volumes)

```bash
kubectl delete pvc -n sre-ai-agent-llm --all
```

### 3. Delete ECR images (optional — reduces storage cost)

```bash
aws ecr batch-delete-image \
  --repository-name sre-ai-agent-app \
  --region ap-south-1 \
  --image-ids "$(aws ecr list-images --repository-name sre-ai-agent-app --region ap-south-1 --query 'imageIds[*]' --output json)"

aws ecr batch-delete-image \
  --repository-name sre-ai-agent-llm \
  --region ap-south-1 \
  --image-ids "$(aws ecr list-images --repository-name sre-ai-agent-llm --region ap-south-1 --query 'imageIds[*]' --output json)"
```

### 4. Delete EKS cluster (this also deletes VPC, subnets, node groups)

```bash
eksctl delete cluster \
  --name sre-ai-agent-cluster \
  --region ap-south-1
```

> This takes ~10 minutes. It removes all EC2 instances, the EKS control plane, and the VPC.

### 5. Delete IAM policies (optional — no cost)

```bash
aws iam delete-policy \
  --policy-arn arn:aws:iam::${AWS_ACCOUNT_ID}:policy/AWSLoadBalancerControllerIAMPolicy

aws iam delete-policy \
  --policy-arn arn:aws:iam::${AWS_ACCOUNT_ID}:policy/SREAgentBedrockPolicy

aws iam delete-policy \
  --policy-arn arn:aws:iam::${AWS_ACCOUNT_ID}:policy/SREPromtailCloudWatchPolicy
```

### 6. Delete CloudWatch Log Group (optional)

```bash
aws logs delete-log-group \
  --log-group-name /sre-ai-agent/k8s \
  --region ap-south-1
```

### 7. Verify everything is gone

```bash
# No running EC2 instances
aws ec2 describe-instances \
  --filters "Name=tag:Project,Values=sre-ai-agent" \
  --query 'Reservations[*].Instances[*].InstanceId' \
  --region ap-south-1

# No EKS cluster
aws eks list-clusters --region ap-south-1

# No ALB
aws elbv2 describe-load-balancers --region ap-south-1
```
