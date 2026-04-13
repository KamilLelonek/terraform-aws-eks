locals {
  # 2 AZs cover HA minimum. Extend to 3 by changing the slice limit;
  # subnet CIDR offsets scale automatically via count.index.
  azs = slice(data.aws_availability_zones.available.names, 0, 2)

  tags = {
    Project     = var.project
    Environment = var.environment
    ManagedBy   = "terraform"
  }

}
