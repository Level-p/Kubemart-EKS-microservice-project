variable "domain" {
  description = "Public Route 53 hosted zone you own"
  type        = string
  default     = "mfon21.space"
}

variable "region" {
  type    = string
  default = "eu-west-2"
}

variable "github_repository" {
  description = "GitHub repository allowed to deploy, in OWNER/REPO form (no https://github.com/, no .git)"
  type        = string
  default     = "Level-p/Kubemart-EKS-microservice-project"

  # GitHub identifies the repository as OWNER/REPO; anything else never matches
  validation {
    condition     = can(regex("^[A-Za-z0-9-]+/[A-Za-z0-9._-]+$", var.github_repository)) && !endswith(var.github_repository, ".git")
    error_message = "Use OWNER/REPO exactly as in the GitHub URL, without https://github.com/ and without .git (e.g. Level-p/my-repo)."
  }
}

variable "github_subject_prefix" {
  description = <<-EOT
    The OIDC subject prefix GitHub uses for your repository when "immutable subjects" are on
    (repo:OWNER@ownerId/REPO@repoId). Find it with:
    curl -s https://api.github.com/repos/OWNER/REPO/actions/oidc/customization/sub
    and copy "sub_claim_prefix". Leave empty if that shows "use_immutable_subject": false.
  EOT
  type        = string
  default     = "" # create-remote-state.sh fills this in automatically when needed
}

variable "create_github_oidc_provider" {
  description = "false if the account already has the token.actions.githubusercontent.com provider (create-remote-state.sh detects this)"
  type        = bool
  default     = true
}
