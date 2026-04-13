# --- EKS Cluster IAM ---

resource "aws_iam_role" "eks_cluster" {
  name = "${var.project}-${var.environment}-eks-cluster"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "eks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "eks_cluster" {
  role       = aws_iam_role.eks_cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

# --- EKS Cluster ---

resource "aws_eks_cluster" "main" {
  # Use var.cluster_name so the cluster name matches what ArgoCD registers.
  # Apply once per environment with the appropriate cluster_name and state key.
  name     = var.cluster_name
  version  = "1.35"
  role_arn = aws_iam_role.eks_cluster.arn

  enabled_cluster_log_types = ["api", "audit", "authenticator"]

  vpc_config {
    subnet_ids              = concat(aws_subnet.private[*].id, aws_subnet.public[*].id)
    endpoint_private_access = true
    endpoint_public_access  = true
    # Restrict public endpoint to known CIDRs in production.
    # Example: public_access_cidrs = ["203.0.113.0/24"]
    # Default (empty) allows 0.0.0.0/0 - acceptable for dev, tighten for prd.
  }

  depends_on = [
    aws_iam_role_policy_attachment.eks_cluster,
    aws_cloudwatch_log_group.eks,
  ]
}

# Explicit log group with 30-day retention.
# Without this, EKS auto-creates the group with infinite retention (unbounded cost).
# Name must match the pattern EKS expects: /aws/eks/<cluster-name>/cluster.
resource "aws_cloudwatch_log_group" "eks" {
  name              = "/aws/eks/${var.cluster_name}/cluster"
  retention_in_days = 30
}

# OIDC provider enables IRSA: K8s ServiceAccounts can assume IAM roles
# without static credentials via STS AssumeRoleWithWebIdentity.
data "tls_certificate" "eks" {
  url = aws_eks_cluster.main.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "eks" {
  url             = aws_eks_cluster.main.identity[0].oidc[0].issuer
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks.certificates[0].sha1_fingerprint]
}

# --- Node Group IAM ---

resource "aws_iam_role" "eks_nodes" {
  name = "${var.project}-${var.environment}-eks-nodes"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "eks_nodes" {
  for_each = toset([
    "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy",
    "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy",
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly",
  ])
  role       = aws_iam_role.eks_nodes.name
  policy_arn = each.value
}

# --- Managed Node Group ---

resource "aws_eks_node_group" "main" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "${var.project}-${var.environment}-nodes"
  node_role_arn   = aws_iam_role.eks_nodes.arn
  subnet_ids      = aws_subnet.private[*].id

  ami_type = "AL2023_x86_64_STANDARD"
  # t3.medium (2 vCPU, 4 GB): sufficient for this workload (nginx, cert-manager,
  # ArgoCD, spring-boot-api). Size up if pod resource requests exceed node capacity
  # or if the Cluster Autoscaler frequently hits the ceiling. Graviton (t4g) gives
  # ~20% better price-performance if all container images are multi-arch.
  instance_types = ["t3.medium"]

  scaling_config {
    desired_size = 2
    min_size     = 2
    max_size     = 10
  }

  update_config {
    max_unavailable = 1
  }

  # Cluster Autoscaler adjusts desired_size at runtime.
  # Without ignore_changes, every terraform apply resets it to 2.
  lifecycle {
    ignore_changes = [scaling_config[0].desired_size]
  }

  depends_on = [aws_iam_role_policy_attachment.eks_nodes]
}

# --- EKS Addons ---
# Core cluster components managed as EKS addons for lifecycle (version upgrades,
# patching) independent of the cluster version upgrade.
# Without these, the cluster has no pod networking, DNS, or service routing.

resource "aws_eks_addon" "vpc_cni" {
  cluster_name                = aws_eks_cluster.main.name
  addon_name                  = "vpc-cni"
  resolve_conflicts_on_update = "OVERWRITE"
}

resource "aws_eks_addon" "coredns" {
  cluster_name                = aws_eks_cluster.main.name
  addon_name                  = "coredns"
  resolve_conflicts_on_update = "OVERWRITE"

  # CoreDNS schedules pods onto worker nodes - node group must exist first.
  depends_on = [aws_eks_node_group.main]
}

resource "aws_eks_addon" "kube_proxy" {
  cluster_name                = aws_eks_cluster.main.name
  addon_name                  = "kube-proxy"
  resolve_conflicts_on_update = "OVERWRITE"
}
