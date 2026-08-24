resource "aws_ecr_repository" "backend" {
  name = "${var.project_name}/backend"

  # Immutable tags: a pushed tag (sha-<git sha>) can never be overwritten,
  # which is what makes Git-based promotion and rollback trustworthy.
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }

  # Demo convenience: allow `terraform destroy` even when images exist.
  force_delete = true
}

# Keep the repository tidy: drop untagged layers quickly and cap the number of
# retained demo images.
resource "aws_ecr_lifecycle_policy" "backend" {
  repository = aws_ecr_repository.backend.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged images after 7 days"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 7
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Keep only the last 15 sha-tagged images"
        selection = {
          tagStatus     = "tagged"
          tagPrefixList = ["sha-"]
          countType     = "imageCountMoreThan"
          countNumber   = 15
        }
        action = { type = "expire" }
      }
    ]
  })
}
