output "argocd_url" {
  value = "https://${local.argocd_host}"
}

output "admin_password_command" {
  description = "Initial admin password (user: admin). Change it, then delete the secret."
  value       = "kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
}
