resource "random_password" "db" {
  length  = 16
  special = false # Avoid chars that break connection string parsing (& @ /)
}

resource "aws_db_subnet_group" "main" {
  name       = "${var.project}-${var.environment}"
  subnet_ids = aws_subnet.private[*].id
}

resource "aws_db_instance" "main" {
  identifier     = "${var.project}-${var.environment}"
  engine         = "postgres"
  engine_version = "17"
  instance_class = "db.t4g.micro" # Graviton3 - ~20% cheaper than t3, better perf

  db_name  = var.db_name
  username = var.db_username

  # Write-only password: generated locally, applied to RDS, never stored in state.
  # Requires: random provider >= 3.7, AWS provider >= 5.80, Terraform >= 1.11.
  # To rotate: bump var.db_password_version (e.g. "v1" -> "v2") and re-apply.
  password_wo         = random_password.db.result_wo
  password_wo_version = var.db_password_version

  storage_type      = "gp3" # gp3 is cheaper and faster than gp2 default
  allocated_storage = 20

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds.id]

  multi_az            = true # Synchronous standby replica in second AZ; ~60s automatic failover
  storage_encrypted   = true
  deletion_protection = true # Requires manual disable before destroy

  backup_retention_period   = 7
  final_snapshot_identifier = "${var.project}-${var.environment}-final-snapshot"
}
