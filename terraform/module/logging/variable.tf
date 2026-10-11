variable "domain_name" {
  type = string
}

variable "certificate_arn" {
  type = string
}

variable "alb_group_name" {
  description = "IngressGroup shared with Argo CD (one ALB for the platform tools)"
  type        = string
}

variable "storage_class_name" {
  type = string
}

variable "enable_service_monitor" {
  description = "Create a ServiceMonitor for Fluent Bit (needs kube-prometheus-stack installed first)"
  type        = bool
  default     = true
}

variable "elastic_version" {
  description = "Elasticsearch and Kibana version"
  type        = string
  default     = "9.4.8"
}

variable "elasticsearch_node_count" {
  type    = number
  default = 1
}

variable "elasticsearch_storage_size" {
  type    = string
  default = "30Gi"
}

variable "eck_operator_chart_version" {
  type    = string
  default = "3.5.0"
}

variable "fluent_bit_chart_version" {
  type    = string
  default = "0.58.3"
}
