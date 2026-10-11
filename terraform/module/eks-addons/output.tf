output "storage_class_name" {
  value = kubernetes_storage_class_v1.gp3.metadata[0].name
}

# Other modules depend on this so their Ingresses are created after the controller
output "load_balancer_controller_ready" {
  value = helm_release.lbc.status
}

output "lbc_role_arn" {
  value = aws_iam_role.lbc.arn
}

output "external_dns_role_arn" {
  value = aws_iam_role.external_dns.arn
}
