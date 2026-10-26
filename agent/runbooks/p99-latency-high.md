# Runbook: High p99 Latency

## Alert
`P99LatencyHigh` — `histogram_quantile(0.99, rate(http_request_duration_seconds_bucket[5m])) > 2`

## Possible Causes
1. Database slow queries — missing index, table bloat
2. Bedrock API latency spike — check AWS Service Health
3. CPU throttling — container hitting CPU limit
4. Network congestion — inter-AZ traffic or NAT bottleneck
5. HPA not scaled up fast enough — traffic spike

## Diagnosis Steps
1. Check Bedrock latency: CloudWatch → Bedrock → `InvocationLatency` metric
2. Check pgvector query time: `kubectl exec pgvector-0 -n sre-ai-agent-llm -- psql -U postgres -d sre_agent -c "SELECT * FROM pg_stat_activity WHERE state='active';"`
3. Check CPU throttling: `kubectl top pods -n sre-ai-agent` — look for high CPU %
4. Check HPA events: `kubectl describe hpa -n sre-ai-agent`
5. Check node pressure: `kubectl describe nodes | grep -A5 Conditions`

## Resolution
- DB slow query: `VACUUM ANALYZE runbook_chunks;` or add index
- CPU throttle: increase `resources.limits.cpu` or trigger manual scale: `kubectl scale deployment sre-ai-agent-app --replicas=5 -n sre-ai-agent`
- Bedrock spike: add retry with exponential backoff in agent code
- HPA too slow: reduce `--horizontal-pod-autoscaler-sync-period`
