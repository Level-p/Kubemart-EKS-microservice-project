variable "cluster_name" {
  type = string
}

variable "region" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "domain_name" {
  description = "Public Route 53 hosted zone that ExternalDNS manages"
  type        = string
}

variable "hosted_zone_id" {
  description = "ID of that hosted zone"
  type        = string
}

variable "storage_reclaim_policy" {
  description = "Delete removes the EBS volume with the PVC; Retain keeps it (safer for production data)"
  type        = string
  default     = "Delete"
}

# Chart versions are pinned so every apply is repeatable
variable "lbc_chart_version" {
  type    = string
  default = "3.5.0"
}

variable "external_dns_chart_version" {
  type    = string
  default = "1.23.0"
}

variable "metrics_server_chart_version" {
  type    = string
  default = "3.14.0"
}
