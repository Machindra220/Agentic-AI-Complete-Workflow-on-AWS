# Runbook: High HTTP Error Rate

## Alert
`HighErrorRate` — `rate(http_requests_total{status=~"5.."}[5m]) / rate(http_requests_total[5m]) > 0.05`

## Possible Causes
1. Upstream dependency down (database, external API)
2. Application bug introduced by recent deployment
3. Resource exhaustion (CPU throttling, memory pressure)
4. Bad configuration — wrong env var or secret value

## Diagnosis Steps
1. Check recent deployments: `kubectl rollout history deployment/sre-ai-agent-app -n sre-ai-agent`
2. Tail logs: `kubectl logs -n sre-ai-agent -l app=sre-ai-agent-app --tail=100`
3. Check DB connectivity: `kubectl exec -n sre-ai-agent-llm pgvector-0 -- pg_isready`
4. Check CPU/memory: `kubectl top pods -n sre-ai-agent`
5. Check HPA: `kubectl get hpa -n sre-ai-agent`

## Resolution
- Recent bad deploy: `kubectl rollout undo deployment/sre-ai-agent-app -n sre-ai-agent`
- DB down: restart pgvector pod, check PVC is bound
- CPU throttling: increase `resources.limits.cpu` or HPA maxReplicas
- Config error: `kubectl describe configmap -n sre-ai-agent` and verify values

## Prevention
- Set `minReadySeconds: 10` on deployments to catch fast-fail restarts
- Add readiness probes so bad pods never receive traffic
