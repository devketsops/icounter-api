resource "aws_ecr_repository" "main" {
  name                 = "${var.project_name}-api"
  image_tag_mutability = "MUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = {
    Name        = "${var.project_name}-api"
    Environment = var.environment
  }
}

resource "aws_ecr_lifecycle_policy" "main" {
  repository = aws_ecr_repository.main.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep last 10 untagged images"
      selection = {
        tagStatus   = "untagged"
        countType   = "imageCountMoreThan"
        countNumber = 10
      }
      action = {
        type = "expire"
      }
    }]
  })
}
