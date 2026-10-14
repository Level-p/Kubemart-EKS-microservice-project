variable "name" {
  description = "Prefix for the S3 bucket and IAM role"
  type        = string
}

variable "cluster_name" {
  type = string
}

variable "storage_class_name" {
  type = string
}

variable "retention_days" {
  description = "Days of logs kept in Loki (and S3)"
  type        = number
  default     = 7
}

variable "loki_chart_version" {
  type    = string
  default = "7.3.0"
}

variable "alloy_chart_version" {
  type    = string
  default = "1.13.1"
}
