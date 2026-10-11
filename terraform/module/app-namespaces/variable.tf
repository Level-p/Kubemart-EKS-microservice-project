variable "name" {
  description = "Base name, e.g. kubemart"
  type        = string
}

variable "cluster_name" {
  type = string
}

variable "environments" {
  description = "Environment name => settings. One namespace kubemart-<name> per entry."
  type = map(object({
    backup_retention_days = number
  }))
}

variable "force_destroy_backups" {
  description = "Let terraform destroy delete the backup bucket even if it still holds backups (true for labs; set false for real data)"
  type        = bool
  default     = true
}
