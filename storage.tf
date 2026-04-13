# Account ID suffix ensures globally unique name without manual coordination
resource "aws_s3_bucket" "main" {
  bucket = "${var.project}-${var.environment}-${data.aws_caller_identity.current.account_id}"
}

resource "aws_s3_bucket_versioning" "main" {
  bucket = aws_s3_bucket.main.id
  versioning_configuration { status = "Enabled" }
}

# Expire noncurrent versions after 30 days to avoid unbounded storage growth.
resource "aws_s3_bucket_lifecycle_configuration" "main" {
  bucket = aws_s3_bucket.main.id

  rule {
    id     = "expire-noncurrent-versions"
    status = "Enabled"

    noncurrent_version_expiration {
      noncurrent_days = 30
    }
  }
}

# SSE-S3 is AWS default since Apr 2023 - omitted intentionally.
# Upgrade to aws_s3_bucket_server_side_encryption_configuration with KMS if needed.

resource "aws_s3_bucket_public_access_block" "main" {
  bucket                  = aws_s3_bucket.main.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# --- AWS Secrets Manager ---

resource "aws_secretsmanager_secret" "app" {
  name = "/spring-boot-api/${var.environment}/credentials"
}

resource "aws_secretsmanager_secret_version" "app" {
  secret_id = aws_secretsmanager_secret.app.id

  # Placeholder JSON matching the structure expected by ESO dataFrom.extract.
  # IMPORTANT: replace these values with real secrets before deploying the app.
  # ESO syncs within refreshInterval (1h) after this is updated.
  # Terraform will NOT overwrite manual updates due to ignore_changes below.
  secret_string = jsonencode({
    APP_SECRET_KEY = "REPLACE_ME"
    DB_PASSWORD    = "REPLACE_ME"
    JWT_SECRET     = "REPLACE_ME"
  })

  # Ignore changes so rotating secrets via console/CLI is not reverted on next apply.
  lifecycle {
    ignore_changes = [secret_string]
  }
}
