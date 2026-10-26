# Runbook: Pod Not Scheduled / Pending

## Alert
`PodPending` — `kube_pod_status_phase{phase="Pending"} > 0` for >5 minutes

## Possible Causes
1. Insufficient cluster capacity — no node has enough CPU/memory
2. Taint/toleration mismatch — pod needs toleration for node taint
3. NodeSelector/affinity not matching any node
4. PVC pending — EBS volume not provisioned (quota or AZ mismatch)
5. Image pull secret missing — ECR auth expired

## Diagnosis Steps
1. `kubectl describe pod <pod> -n <namespace>` — read Events section
2. Look for: `Insufficient cpu`, `Insufficient memory`, `no nodes available`
3. Check node capacity: `kubectl describe nodes | grep -A10 "Allocated resources"`
4. Check PVC: `kubectl get pvc -n <namespace>`
5. Check ECR pull secret: `kubectl get secret ecr-pull-secret -n <namespace>`

## Resolution
- No capacity: check if node group ASG has reached `max_size` in Terraform; increase `agent_node_max` and re-apply
- Taint mismatch: add toleration to pod spec or fix node group taint
- PVC stuck: `kubectl describe pvc <name> -n <namespace>` — check StorageClass is `gp2` and EBS CSI driver is running
- ECR secret expired: re-run `aws ecr get-login-password` and recreate secret
