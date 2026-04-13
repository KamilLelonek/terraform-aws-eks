data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_caller_identity" "current" {}

# Short-lived token for the EKS cluster. Evaluated at apply time after the
# cluster exists - no static credentials or aws CLI exec required.
data "aws_eks_cluster_auth" "main" {
  name = aws_eks_cluster.main.name
}
