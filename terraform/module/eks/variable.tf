variable "cluster_name" {
  description = "Name of the EKS cluster"
  type        = string
}

variable "kubernetes_version" {
  description = "Kubernetes version. Check supported versions with: aws eks describe-cluster-versions"
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnets for the control plane ENIs and the worker nodes"
  type        = list(string)
}

variable "public_access_cidrs" {
  description = "CIDRs allowed to reach the public Kubernetes API endpoint"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "admin_principal_arns" {
  description = "IAM user/role ARNs that get cluster-admin through EKS access entries. Must include whoever runs Terraform."
  type        = list(string)
}

variable "instance_types" {
  description = "EC2 instance types for the managed node group"
  type        = list(string)
  default     = ["t3.large"]
}

variable "capacity_type" {
  description = "ON_DEMAND or SPOT"
  type        = string
  default     = "ON_DEMAND"
}

variable "node_desired_size" {
  type    = number
  default = 3
}

variable "node_min_size" {
  type    = number
  default = 2
}

variable "node_max_size" {
  type    = number
  default = 5
}

variable "node_disk_size" {
  description = "Root volume size (GiB) for each worker node"
  type        = number
  default     = 50
}

variable "log_retention_days" {
  description = "CloudWatch retention for control plane logs"
  type        = number
  default     = 7
}
