# Architecture & Security Reference

## Security Design Principles

This project follows **least privilege, defence-in-depth** across every layer.

### 1. IAM / IRSA

| Service Account | Namespace | IAM Policy | Scope |
|---|---|---|---|
| `aws-load-balancer-controller` | `kube-system` | `AWSLoadBalancerControllerIAMPolicy` | EC2 + ELB only |
| `sre-agent-sa` | `sre-ai-agent-llm` | `SREAgentBedrockPolicy` | `bedrock:InvokeModel` on specific model ARNs only |
| `promtail-sa` | `monitoring` | `SREPromtailCloudWatchPolicy` | `logs:PutLogEvents` on `/sre-ai-agent/*` only |

**IRSA** (IAM Roles for Service Accounts) means:
- No static AWS keys anywhere in the cluster
- Each pod gets a short-lived STS token via OIDC
- Pod identity is cryptographically bound to the K8s service account

### 2. Secrets Management

| Secret | How stored | Where used |
|---|---|---|
| Grafana Cloud API Key | K8s `Secret` in `monitoring` ns | Prometheus remote_write |
| ECR pull credential | K8s `Secret` (docker-registry type) | imagePullSecrets on Deployments |
| Bedrock access | **No secret** — IRSA token only | LangGraph agent |

**Never** store secrets in:
- Environment variables baked into Docker images
- ConfigMaps
- Git history

### 3. Network Security

- Worker nodes in **private subnets** — no public IPs
- Only ALBs are public-facing
- Kubernetes `NetworkPolicy` restricts pod-to-pod traffic:
  - `sre-ai-agent` → can only be reached from monitoring namespace (Prometheus scrape) and chaos namespace (chaoskube delete)
  - `sre-ai-agent-llm` → reachable only from ALB (webhook) and `sre-ai-agent`
  - `chaos` → egress only to kube-api-server

### 4. Container Security

- ECR repos have **scan-on-push** enabled (Amazon Inspector)
- Pods run as **non-root** (`runAsNonRoot: true`)
- Read-only root filesystem where possible
- No `privileged: true` containers
- Resource limits set on every container (prevents noisy-neighbour on t3.small)

### 5. EKS Cluster Hardening

- **Private networking** for worker nodes
- API server endpoint: both public + private (restrict `publicAccessCIDRs` to your IP)
- Kubernetes version: 1.29 (supported, regular updates)
- Managed node groups: automatic security patch rotation

---

## Data Flow

```
[chaoskube] --DELETE pod--> [Kubernetes API]
                                  |
                         pod restarts → counter++
                                  |
[Prometheus] --scrape /metrics--> [kube-state-metrics]
[Prometheus] --remote_write-----> [Grafana Cloud Mimir]
                                  |
                         alert rule fires (rate > threshold)
                                  |
[Grafana Cloud] --POST----------> [ALB] --> [/agent/triage]
                                                    |
                                     [LangGraph Agent - sre-ai-agent-llm]
                                       alert_parser
                                            |
                                     runbook_retriever (pgvector)
                                            |
                                     diagnoser (Bedrock Claude)
                                            |
                                     rca_writer → stdout
                                            |
[Promtail DaemonSet] --PutLogEvents--> [CloudWatch Logs /sre-ai-agent/k8s]
                                            |
                               [Grafana Dashboard - CloudWatch datasource]
```

---

## Cost Estimate (ap-south-1, free tier)

| Resource | Monthly cost |
|---|---|
| 4× t3.small EC2 (720h) | ~$30 (use free credits) |
| EKS cluster fee | $0.10/hr = ~$73 (free credits) |
| ECR storage (<500MB) | $0 first year |
| CloudWatch Logs (5GB) | $0 first 5GB/month |
| ALB | ~$5 (use free credits) |
| Bedrock (Claude 3 Haiku, light RCA calls) | ~$1–2 |
| Grafana Cloud | $0 (free tier) |

> **Tip:** Run `eksctl delete cluster` when not actively developing — EKS + EC2 charges continue even when idle.
