variable "repositories" {
  description = "ECR repository names to create"
  type        = list(string)
}

variable "max_image_count" {
  description = "How many images to keep per repository"
  type        = number
  default     = 30
}

variable "force_delete" {
  description = "Delete repositories even if they still contain images (handy for labs)"
  type        = bool
  default     = true
}
