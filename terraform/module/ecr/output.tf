output "repository_urls" {
  description = "Map of repository name => URI"
  value       = { for k, r in aws_ecr_repository.repo : k => r.repository_url }
}

output "registry_id" {
  value = one(distinct([for r in aws_ecr_repository.repo : r.registry_id]))
}
