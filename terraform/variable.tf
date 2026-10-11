variable "region" {
  description = "AWS region"
  type        = string
  default     = "eu-west-2"
}

variable "domain_name" {
  description = "The primary domain name for the Route 53 hosted zone"
  type        = string
  default     = "mfon21.space"
}

variable "kubernetes_version" {
  description = "EKS Kubernetes version (check: aws eks describe-cluster-versions --region eu-west-2)"
  type        = string
  default     = "1.35"
}

variable "node_instance_types" {
  description = "Elasticsearch needs memory, so use at least t3.large"
  type        = list(string)
  default     = ["t3.large"]
}

variable "admin_principal_arns" {
  description = <<-EOT
    Extra IAM user/role ARNs that get cluster-admin on EKS.
    The GitHub Actions role from the bootstrap stack is added automatically. Add YOUR IAM ARN to use kubectl
    from your laptop, e.g. ["arn:aws:iam::123456789012:user/steven"].
  EOT
  type        = list(string)
  default     = []
}

variable "environments" {
  description = "KubeMart environments: one namespace kubemart-<name> each, and how many days its nightly database backups are kept"
  type = map(object({
    backup_retention_days = number
  }))
  default = {
    stage = { backup_retention_days = 7 }
    prod  = { backup_retention_days = 30 }
  }
}

variable "expose_prometheus" {
  description = "Publish Prometheus on https://prometheus.<domain> (it has no login, so keep false and use kubectl port-forward)"
  type        = bool
  default     = false
}

variable "git_repo_url" {
  description = "HTTPS URL of THIS repository (Argo CD reads app/helm/ecommerce from it)"
  type        = string
  default     = "https://github.com/your-github-user/kubemart.git"
}

variable "git_revision" {
  description = "Branch Argo CD watches"
  type        = string
  default     = "main"
}

variable "git_repo_token" {
  description = "Read-only GitHub token if the repository is private (the workflow passes the GIT_REPO_TOKEN secret as TF_VAR_git_repo_token)"
  type        = string
  default     = ""
  sensitive   = true
}
