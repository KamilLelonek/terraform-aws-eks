# --- Kubernetes add-ons ---
# Installed via Helm into the EKS cluster created in compute.tf.
# wait = true blocks Terraform until each release is healthy before moving on.
#
# ArgoCD config (ClusterIssuers, AppProject, ApplicationSet) is managed by the
# application repo and applied separately after infra is ready.

# --- nginx Ingress Controller ---
# Creates a LoadBalancer Service that AWS provisions as an NLB (Layer 4).
# NLB is the right choice here: nginx handles all L7 concerns (TLS termination,
# path routing, virtual hosts), so the AWS load balancer only needs to forward
# TCP. An ALB in front of nginx would be redundant L7 processing.
# The public subnets are tagged kubernetes.io/role/elb = 1 (see network.tf)
# so AWS can discover them when provisioning the NLB.
resource "helm_release" "ingress_nginx" {
  name             = "ingress-nginx"
  repository       = "https://kubernetes.github.io/ingress-nginx"
  chart            = "ingress-nginx"
  version          = "4.11.3"
  namespace        = "ingress-nginx"
  create_namespace = true
  wait             = true
  timeout          = 600

  depends_on = [aws_eks_node_group.main]
}

# --- cert-manager ---
# Automates TLS certificate issuance and renewal via Let's Encrypt.
# crds.enabled installs cert-manager CRDs via the Helm chart itself so no
# separate kubectl apply is needed.
resource "helm_release" "cert_manager" {
  name             = "cert-manager"
  repository       = "https://charts.jetstack.io"
  chart            = "cert-manager"
  version          = "1.16.2"
  namespace        = "cert-manager"
  create_namespace = true
  wait             = true
  timeout          = 600

  set = [{
    name  = "crds.enabled"
    value = "true"
  }]

  depends_on = [aws_eks_node_group.main]
}

# --- ArgoCD ---
resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = "7.7.11"
  namespace        = "argocd"
  create_namespace = true
  wait             = true
  timeout          = 600

  depends_on = [aws_eks_node_group.main]
}
