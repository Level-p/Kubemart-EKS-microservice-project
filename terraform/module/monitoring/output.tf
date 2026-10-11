output "grafana_url" {
  value = "https://${local.grafana_host}"
}

output "prometheus_url" {
  value = var.expose_prometheus ? "https://${local.prometheus_host}" : "kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090"
}

output "grafana_admin_password_command" {
  description = "Grafana login: user admin, password from this command"
  value       = "kubectl get secret kube-prometheus-stack-grafana -n monitoring -o jsonpath='{.data.admin-password}' | base64 -d"
}

output "namespace" {
  value = helm_release.kube_prometheus_stack.namespace
}
