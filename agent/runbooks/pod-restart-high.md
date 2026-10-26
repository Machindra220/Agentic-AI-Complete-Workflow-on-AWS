# Runbook: High Pod Restart Rate

## Alert
`PodRestartRateHigh` — `rate(kube_pod_container_restarts_total[2m]) > 0.1`

## Possible Causes
1. OOMKilled — container exceeding memory limit
2. CrashLoopBackOff — application error on startup
3. Liveness probe failing — app unhealthy, K8s killing it
4. Image pull error — bad tag or ECR auth expired
5. Config/secret missing — env var or mounted secret not found

## Diagnosis Steps
1. `kubectl describe pod <pod> -n <namespace>` — check Last State reason
2. `kubectl logs <pod> -n <namespace> --previous` — logs before restart
3. `kubectl top pod <pod> -n <namespace>` — check memory usage vs limit
4. Check Events section for OOMKilled or ImagePullBackOff

## Resolution
- OOMKilled: increase `resources.limits.memory` in Deployment spec
- CrashLoopBackOff: fix application startup error (check logs)
- Probe failure: tune `initialDelaySeconds` or fix health endpoint
- Image pull: run `aws ecr get-login-password | docker login` and re-push
- Missing secret: `kubectl get secret <name> -n <namespace>`

## Escalation
If restarts continue >10 in 5 minutes, page on-call SRE.
