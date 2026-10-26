#!/usr/bin/env bash
# Teardown — destroys all AWS resources to stop billing.
# Run: bash scripts/infra-down.sh
set -euo pipefail

TERRAFORM_DIR="$(dirname "$0")/../terraform"

echo "⚠  This will DESTROY the EKS cluster and all Terraform-managed resources."
echo "   EC2, VPC, ECR images, IAM roles, CloudWatch log group."
read -r -p "   Type 'destroy' to confirm: " CONFIRM
[[ "$CONFIRM" == "destroy" ]] || { echo "Aborted."; exit 0; }

cd "$TERRAFORM_DIR"
terraform destroy -auto-approve

echo ""
echo "✅  Infrastructure destroyed."
echo "    ECR repos are deleted by Terraform only if they are empty."
echo "    To force-delete ECR images first, see docs/runbook-teardown.md"
