variable "region" {
  description = "AWS region"
  type        = string
  default     = "eu-central-1"
}

variable "project" {
  description = "Project name used as resource prefix"
  type        = string
  default     = "webapp"
}

variable "environment" {
  description = "Deployment environment. Must match the env key used in K8s values files and SM secret paths (dev / prd)."
  type        = string
  default     = "dev"

  validation {
    condition     = contains(["dev", "prd"], var.environment)
    error_message = "environment must be 'dev' or 'prd'."
  }
}

variable "db_name" {
  description = "PostgreSQL database name"
  type        = string
  default     = "appdb"
}

variable "db_username" {
  description = "PostgreSQL master username"
  type        = string
  default     = "dbadmin"
}

variable "db_password_version" {
  description = "Bump to rotate DB password (triggers re-apply of write-only value without exposing it in state)"
  type        = string
  default     = "v1"
}

variable "cluster_name" {
  description = "EKS cluster name. Must match the name registered in ArgoCD (argocd cluster add). Apply this module once per cluster with the correct name and a separate state key per environment."
  type        = string
  # Examples: dev-global-cluster-0, prd-global-cluster-5
}

variable "acme_email" {
  description = "Email for Let's Encrypt ACME account registration. cert-manager sends certificate expiry warnings to this address."
  type        = string
}
