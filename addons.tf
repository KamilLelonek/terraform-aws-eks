# --- Kubernetes add-ons ---
# Installed via Helm into the EKS cluster created in compute.tf.
# wait = true blocks Terraform until each release is healthy before moving on,
# so CRD-backed resources (ClusterIssuer, Application) are applied only
# after their CRDs exist.

# --- nginx Ingress Controller ---
# Provisions an internet-facing AWS NLB in the public subnets.
# The subnets are tagged kubernetes.io/role/elb = 1 (see network.tf) so the
# AWS Load Balancer Controller can discover them automatically.
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

# ClusterIssuers: tell cert-manager how to request certificates from Let's Encrypt.
# kubectl_manifest defers CRD schema validation to apply time (not plan time),
# so these can be created in the same apply as the cert-manager Helm release.
#
# staging: untrusted cert, ~3000x higher rate limits - use for dev and TLS config iteration.
# prod:    browser-trusted, rate-limited to 50 certs/week per domain - switch after staging works.
resource "kubectl_manifest" "cluster_issuer_staging" {
  yaml_body = yamlencode({
    apiVersion = "cert-manager.io/v1"
    kind       = "ClusterIssuer"
    metadata   = { name = "letsencrypt-staging" }
    spec = {
      acme = {
        server              = "https://acme-staging-v02.api.letsencrypt.org/directory"
        email               = var.acme_email
        privateKeySecretRef = { name = "letsencrypt-staging-account-key" }
        solvers             = local.acme_solver
      }
    }
  })

  depends_on = [helm_release.cert_manager]
}

resource "kubectl_manifest" "cluster_issuer_prod" {
  yaml_body = yamlencode({
    apiVersion = "cert-manager.io/v1"
    kind       = "ClusterIssuer"
    metadata   = { name = "letsencrypt-prod" }
    spec = {
      acme = {
        server              = "https://acme-v02.api.letsencrypt.org/directory"
        email               = var.acme_email
        privateKeySecretRef = { name = "letsencrypt-prod-account-key" }
        solvers             = local.acme_solver
      }
    }
  })

  depends_on = [helm_release.cert_manager]
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

# AppProject: scopes the spring-boot-api application to its own repo and namespace.
# Prevents accidental cross-project resource creation.
resource "kubectl_manifest" "argocd_project" {
  yaml_body = <<-YAML
    apiVersion: argoproj.io/v1alpha1
    kind: AppProject
    metadata:
      name: spring-boot
      namespace: argocd
    spec:
      description: Spring Boot API
      sourceRepos:
        - https://github.com/inpost/spring-boot-api
      destinations:
        - namespace: spring-boot-api
          server: https://kubernetes.default.svc
      clusterResourceWhitelist:
        - group: ""
          kind: Namespace
  YAML

  depends_on = [helm_release.argocd]
}

# ArgoCD Application: deploys the spring-boot-api Helm chart to this cluster.
#
# destination.server = https://kubernetes.default.svc means "the cluster ArgoCD
# itself runs on" - no argocd cluster add registration step required.
#
# Multi-source: chart from helm-chart/ at local.chart_revision (HEAD for dev,
# v1.0.0 for prd); env values from environments/{env}/values.yaml always at HEAD
# so config changes deploy without a chart version bump.
# $$values escapes the $ so Terraform passes $values literally to ArgoCD.
resource "kubectl_manifest" "argocd_application" {
  yaml_body = <<-YAML
    apiVersion: argoproj.io/v1alpha1
    kind: Application
    metadata:
      name: spring-boot-api
      namespace: argocd
    spec:
      project: spring-boot
      sources:
        - repoURL: https://github.com/inpost/spring-boot-api
          targetRevision: ${local.chart_revision}
          path: helm-chart/spring-boot-api
          helm:
            valueFiles:
              - $$values/environments/${var.environment}/values.yaml
        - repoURL: https://github.com/inpost/spring-boot-api
          targetRevision: HEAD
          ref: values
      destination:
        server: https://kubernetes.default.svc
        namespace: spring-boot-api
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
        syncOptions:
          - CreateNamespace=true
        retry:
          limit: 3
          backoff:
            duration: 5s
            factor: 2
            maxDuration: 3m
  YAML

  depends_on = [kubectl_manifest.argocd_project]
}
