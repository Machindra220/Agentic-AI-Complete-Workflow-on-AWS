variable "aws_region" {
  description = "AWS region for all resources"
  type        = string
  default     = "ap-south-1"
}

variable "aws_account_id" {
  description = "Your 12-digit AWS account ID"
  type        = string
}

variable "cluster_name" {
  description = "EKS cluster name"
  type        = string
  default     = "sre-ai-agent-cluster"
}

variable "environment" {
  description = "Environment tag (dev / staging / prod)"
  type        = string
  default     = "dev"
}

variable "kubernetes_version" {
  description = "EKS Kubernetes version"
  type        = string
  default     = "1.29"
}

# ── VPC ──────────────────────────────────────────────────────
variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "availability_zones" {
  description = "AZs to use — ap-south-1 has ap-south-1a, 1b, 1c"
  type        = list(string)
  default     = ["ap-south-1a", "ap-south-1b", "ap-south-1c"]
}

variable "private_subnet_cidrs" {
  description = "CIDRs for private subnets (one per AZ) — worker nodes live here"
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
}

variable "public_subnet_cidrs" {
  description = "CIDRs for public subnets (one per AZ) — ALBs live here"
  type        = list(string)
  default     = ["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24"]
}

# ── Node Groups ──────────────────────────────────────────────
variable "app_node_instance_type" {
  description = "EC2 instance type for app nodes"
  type        = string
  default     = "t3.small"
}

variable "app_node_desired" {
  description = "Desired number of app nodes"
  type        = number
  default     = 3
}

variable "app_node_min" {
  type    = number
  default = 2
}

variable "app_node_max" {
  type    = number
  default = 4
}

variable "agent_node_instance_type" {
  description = "EC2 instance type for AI agent node"
  type        = string
  default     = "t3.small"
}

variable "agent_node_desired" {
  type    = number
  default = 1
}

variable "agent_node_min" {
  type    = number
  default = 1
}

variable "agent_node_max" {
  type    = number
  default = 2
}

# ── Bedrock ──────────────────────────────────────────────────
variable "bedrock_model_id" {
  description = "Bedrock foundation model ID used by the LangGraph agent"
  type        = string
  default     = "anthropic.claude-3-haiku-20240307-v1:0"
}

# ── CloudWatch ───────────────────────────────────────────────
variable "cloudwatch_log_group" {
  description = "CloudWatch log group for all K8s pod logs"
  type        = string
  default     = "/sre-ai-agent/k8s"
}

variable "cloudwatch_retention_days" {
  description = "How many days to retain logs in CloudWatch"
  type        = number
  default     = 14
}
