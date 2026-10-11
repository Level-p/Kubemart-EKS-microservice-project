output "cluster_name" {
  value = module.eks.cluster_name
}

output "configure_kubectl" {
  value = "aws eks update-kubeconfig --name ${module.eks.cluster_name} --region ${var.region}"
}

output "ecr_repositories" {
  value = module.ecr.repository_urls
}

output "argocd_url" {
  value = module.argocd.argocd_url
}

output "argocd_admin_password_command" {
  value = module.argocd.admin_password_command
}

output "kibana_url" {
  value = module.logging.kibana_url
}

output "kibana_password_command" {
  value = module.logging.elastic_password_command
}

output "grafana_url" {
  value = module.monitoring.grafana_url
}

output "grafana_admin_password_command" {
  description = "Grafana login: user admin"
  value       = module.monitoring.grafana_admin_password_command
}

output "prometheus_url" {
  value = module.monitoring.prometheus_url
}

output "db_backup_bucket" {
  description = "Nightly pg_dump of every database, one folder per environment"
  value       = module.app_namespaces.backup_bucket
}

output "shop_urls" {
  value = {
    stage = "https://shop-stage.${var.domain_name}"
    prod  = "https://shop.${var.domain_name}"
  }
}
