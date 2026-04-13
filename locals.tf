locals {
  # 2 AZs cover HA minimum. Extend to 3 by changing the slice limit;
  # subnet CIDR offsets scale automatically via count.index.
  azs = slice(data.aws_availability_zones.available.names, 0, 2)

  tags = {
    Project     = var.project
    Environment = var.environment
    ManagedBy   = "terraform"
  }

  # Helm chart revision for the ArgoCD Application.
  # dev tracks HEAD for fast feedback; prd is pinned to a tag for explicit promotion.
  chart_revision = var.environment == "prd" ? "v1.0.0" : "HEAD"

  # Shared ACME HTTP-01 solver used by both ClusterIssuers (staging + prod).
  acme_solver = [{ http01 = { ingress = { ingressClassName = "nginx" } } }]
}
