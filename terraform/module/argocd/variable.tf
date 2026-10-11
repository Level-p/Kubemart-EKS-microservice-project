variable "domain_name" {
  type = string
}

variable "certificate_arn" {
  type = string
}

variable "alb_group_name" {
  type = string
}

variable "git_repo_url" {
  description = "HTTPS URL of the Git repository that contains app/helm/ecommerce"
  type        = string
}

variable "git_revision" {
  description = "Branch Argo CD watches"
  type        = string
  default     = "main"
}

variable "git_repo_username" {
  type    = string
  default = "git"
}

variable "git_repo_token" {
  description = "GitHub personal access token (read-only) for a PRIVATE repo. Leave empty for a public repo."
  type        = string
  default     = ""
  sensitive   = true
}

variable "enable_service_monitors" {
  description = "Create ServiceMonitors for Argo CD (needs kube-prometheus-stack installed first)"
  type        = bool
  default     = true
}

variable "argocd_chart_version" {
  type    = string
  default = "10.9.6"
}

variable "argocd_apps_chart_version" {
  type    = string
  default = "2.0.6"
}
