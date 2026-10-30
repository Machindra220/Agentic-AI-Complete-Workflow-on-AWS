# Namespaces are created in scripts/infra-up.sh via kubectl
# (after kubeconfig update + cluster readiness check) to avoid
# Terraform Kubernetes provider race condition on fresh cluster creation.
