output "kubeconfig_command" {
  description = "Configure kubectl to talk to the cluster"
  value       = "aws eks update-kubeconfig --region ${var.region} --name ${aws_eks_cluster.main.name}"
}

output "argocd_admin_password" {
  description = "Retrieve the ArgoCD initial admin password (username: admin)"
  value       = "kubectl get secret argocd-initial-admin-secret -n argocd -o jsonpath='{.data.password}' | base64 -d"
}

output "db_endpoint" {
  description = "RDS writer endpoint - used in DB_HOST app config"
  value       = aws_db_instance.main.address
}

output "s3_bucket" {
  description = "Application S3 bucket name"
  value       = aws_s3_bucket.main.bucket
}
