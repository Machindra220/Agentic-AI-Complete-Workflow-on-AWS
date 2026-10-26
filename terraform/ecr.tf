# ── ECR Repositories ─────────────────────────────────────────
# Two private repos: one for FastAPI app, one for LangGraph agent.
# Both have scan-on-push and AES256 encryption enabled.

locals {
  ecr_repos = ["sre-ai-agent-app", "sre-ai-agent-llm"]
}

resource "aws_ecr_repository" "repos" {
  for_each = toset(local.ecr_repos)

  name                 = each.key
  image_tag_mutability = "MUTABLE"

  # Security: scan every image pushed for CVEs
  image_scanning_configuration {
    scan_on_push = true
  }

  # Security: encrypt images at rest
  encryption_configuration {
    encryption_type = "AES256"
  }
}

# Lifecycle policy: keep only the 5 most recent images per repo
# (saves storage cost on free tier)
resource "aws_ecr_lifecycle_policy" "repos" {
  for_each   = aws_ecr_repository.repos
  repository = each.value.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep last 5 images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 5
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}
