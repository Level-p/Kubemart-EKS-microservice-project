variable "chart_version" {
  description = "postgres-operator Helm chart version"
  type        = string
  default     = "2.0.3"
}

variable "spilo_image" {
  description = "Spilo image (PostgreSQL + Patroni). The spilo-18 image also runs PostgreSQL 14-17."
  type        = string
  default     = "ghcr.io/zalando/spilo-18:4.1-p2"
}
