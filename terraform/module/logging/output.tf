output "kibana_url" {
  value = "https://${local.kibana_host}"
}

output "elastic_password_command" {
  description = "Kibana login: user elastic, password from this command"
  value       = "kubectl get secret ${local.es_name}-es-elastic-user -n ${local.namespace} -o jsonpath='{.data.elastic}' | base64 -d"
}
