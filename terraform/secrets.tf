# --- AWS Secrets Manager ---

resource "aws_secretsmanager_secret" "db_password" {
  name        = "${var.project_name}/db-password"
  description = "Database password for ${var.project_name} API"

  tags = {
    Name        = "${var.project_name}-db-password"
    Environment = var.environment
  }
}

resource "aws_secretsmanager_secret_version" "db_password" {
  secret_id = aws_secretsmanager_secret.db_password.id
  secret_string = jsonencode({
    password = var.db_password
  })
}

resource "aws_secretsmanager_secret" "api_key" {
  name        = "${var.project_name}/api-key"
  description = "API key for ${var.project_name} API"

  tags = {
    Name        = "${var.project_name}-api-key"
    Environment = var.environment
  }
}

resource "aws_secretsmanager_secret_version" "api_key" {
  secret_id = aws_secretsmanager_secret.api_key.id
  secret_string = jsonencode({
    key = var.api_key
  })
}
