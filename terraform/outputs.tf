# ── Outputs ───────────────────────────────────────────────────
# These values are printed after `terraform apply` and are needed
# for subsequent deployment phases (docker push, kubectl, helm).

output "cluster_name" {
  description = "EKS cluster name — use in: aws eks update-kubeconfig --name <value>"
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "EKS API server endpoint"
  value       = module.eks.cluster_endpoint
}

output "cluster_certificate_authority_data" {
  description = "Base64-encoded CA cert for the cluster"
  value       = module.eks.cluster_certificate_authority_data
  sensitive   = true
}

output "oidc_provider_arn" {
  description = "OIDC provider ARN — used by IRSA trust policies"
  value       = module.eks.oidc_provider_arn
}

output "vpc_id" {
  description = "VPC ID"
  value       = module.vpc.vpc_id
}

output "private_subnet_ids" {
  description = "Private subnet IDs (worker nodes)"
  value       = module.vpc.private_subnets
}

output "public_subnet_ids" {
  description = "Public subnet IDs (ALBs)"
  value       = module.vpc.public_subnets
}

output "ecr_app_url" {
  description = "ECR URL for FastAPI app — use in: docker push <value>:tag"
  value       = aws_ecr_repository.repos["sre-ai-agent-app"].repository_url
}

output "ecr_agent_url" {
  description = "ECR URL for LangGraph agent"
  value       = aws_ecr_repository.repos["sre-ai-agent-llm"].repository_url
}

output "sre_agent_role_arn" {
  description = "IRSA role ARN for LangGraph agent (Bedrock access) — annotate sre-agent-sa with this"
  value       = aws_iam_role.sre_agent.arn
}

output "promtail_role_arn" {
  description = "IRSA role ARN for Promtail (CloudWatch access) — annotate promtail-sa with this"
  value       = aws_iam_role.promtail.arn
}

output "alb_controller_role_arn" {
  description = "IRSA role ARN for ALB Controller"
  value       = aws_iam_role.alb_controller.arn
}

output "cloudwatch_log_group" {
  description = "CloudWatch log group name for K8s pod logs"
  value       = aws_cloudwatch_log_group.sre_agent.name
}

output "update_kubeconfig_command" {
  description = "Run this after apply to configure kubectl"
  value       = "aws eks update-kubeconfig --region ${var.aws_region} --name ${module.eks.cluster_name}"
}
