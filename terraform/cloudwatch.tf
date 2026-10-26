# ── CloudWatch Log Group ─────────────────────────────────────
# Pre-create the log group with encryption and retention policy.
# Promtail will stream pod logs here via the promtail-sa IRSA role.

resource "aws_cloudwatch_log_group" "sre_agent" {
  name              = var.cloudwatch_log_group
  retention_in_days = var.cloudwatch_retention_days

  # Security: encrypt logs at rest using AWS-managed key
  # To use a customer-managed KMS key, replace with kms_key_id = aws_kms_key.logs.arn
}
