variable "domain_name" {
  type = string
}

variable "certificate_arn" {
  description = "ACM certificate (wildcard) for the ALB HTTPS listener"
  type        = string
}

variable "alb_group_name" {
  description = "IngressGroup shared with Argo CD (one ALB for the platform tools)"
  type        = string
}

variable "storage_class_name" {
  type = string
}

variable "expose_prometheus" {
  description = "Prometheus has no login page. Keep false and use kubectl port-forward unless you add authentication."
  type        = bool
  default     = false
}

variable "prometheus_retention" {
  type    = string
  default = "10d"
}

variable "prometheus_storage_size" {
  type    = string
  default = "30Gi"
}

variable "chart_version" {
  type    = string
  default = "91.9.0"
}

variable "loki_url" {
  description = "Loki address for Grafana's data source (module logging)"
  type        = string
}

variable "alert_slack_webhook_url" {
  description = "Slack incoming webhook for Alertmanager. Empty = alerts are only shown in Grafana and Alertmanager"
  type        = string
  default     = ""
  sensitive   = true
}
