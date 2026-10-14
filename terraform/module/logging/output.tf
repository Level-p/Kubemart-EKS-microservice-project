output "loki_url" {
  description = "In-cluster address of Loki (Grafana's Loki data source)"
  value       = "http://loki.${local.namespace}.svc:3100"
}

output "bucket" {
  description = "S3 bucket holding the logs"
  value       = aws_s3_bucket.loki.bucket
}
