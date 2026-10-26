# ── IAM: ALB Controller ──────────────────────────────────────
resource "aws_iam_policy" "alb_controller" {
  name        = "${var.cluster_name}-alb-controller"
  description = "ALB Ingress Controller — least privilege"
  policy      = file("${path.module}/../iam/alb-controller-policy.json")
}

data "aws_iam_policy_document" "alb_controller_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"

    principals {
      type        = "Federated"
      identifiers = [module.eks.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${module.eks.oidc_provider}:sub"
      values   = ["system:serviceaccount:kube-system:aws-load-balancer-controller"]
    }

    condition {
      test     = "StringEquals"
      variable = "${module.eks.oidc_provider}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "alb_controller" {
  name               = "${var.cluster_name}-alb-controller"
  assume_role_policy = data.aws_iam_policy_document.alb_controller_assume.json
}

resource "aws_iam_role_policy_attachment" "alb_controller" {
  role       = aws_iam_role.alb_controller.name
  policy_arn = aws_iam_policy.alb_controller.arn
}

# ── IAM: LangGraph Agent → Bedrock (IRSA) ───────────────────
resource "aws_iam_policy" "bedrock" {
  name        = "${var.cluster_name}-bedrock-invoke"
  description = "Allow LangGraph agent pod to call Bedrock InvokeModel"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "BedrockInvokeModel"
        Effect = "Allow"
        Action = [
          "bedrock:InvokeModel",
          "bedrock:InvokeModelWithResponseStream"
        ]
        Resource = [
          "arn:aws:bedrock:${var.aws_region}::foundation-model/${var.bedrock_model_id}",
          "arn:aws:bedrock:${var.aws_region}::foundation-model/amazon.titan-embed-text-v2:0"
        ]
      },
      {
        Sid      = "BedrockListModels"
        Effect   = "Allow"
        Action   = ["bedrock:ListFoundationModels"]
        Resource = "*"
      }
    ]
  })
}

data "aws_iam_policy_document" "bedrock_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"

    principals {
      type        = "Federated"
      identifiers = [module.eks.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${module.eks.oidc_provider}:sub"
      values   = ["system:serviceaccount:sre-ai-agent-llm:sre-agent-sa"]
    }

    condition {
      test     = "StringEquals"
      variable = "${module.eks.oidc_provider}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "sre_agent" {
  name               = "${var.cluster_name}-sre-agent"
  assume_role_policy = data.aws_iam_policy_document.bedrock_assume.json
}

resource "aws_iam_role_policy_attachment" "sre_agent_bedrock" {
  role       = aws_iam_role.sre_agent.name
  policy_arn = aws_iam_policy.bedrock.arn
}

# ── IAM: Promtail → CloudWatch (IRSA) ───────────────────────
resource "aws_iam_policy" "cloudwatch_logs" {
  name        = "${var.cluster_name}-promtail-cloudwatch"
  description = "Allow Promtail DaemonSet to write to CloudWatch Logs"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "CloudWatchLogsWrite"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "logs:DescribeLogGroups",
          "logs:DescribeLogStreams"
        ]
        Resource = [
          "arn:aws:logs:${var.aws_region}:${var.aws_account_id}:log-group:${var.cloudwatch_log_group}",
          "arn:aws:logs:${var.aws_region}:${var.aws_account_id}:log-group:${var.cloudwatch_log_group}:*"
        ]
      }
    ]
  })
}

data "aws_iam_policy_document" "promtail_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"

    principals {
      type        = "Federated"
      identifiers = [module.eks.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${module.eks.oidc_provider}:sub"
      values   = ["system:serviceaccount:monitoring:promtail-sa"]
    }

    condition {
      test     = "StringEquals"
      variable = "${module.eks.oidc_provider}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "promtail" {
  name               = "${var.cluster_name}-promtail"
  assume_role_policy = data.aws_iam_policy_document.promtail_assume.json
}

resource "aws_iam_role_policy_attachment" "promtail_cloudwatch" {
  role       = aws_iam_role.promtail.name
  policy_arn = aws_iam_policy.cloudwatch_logs.arn
}
