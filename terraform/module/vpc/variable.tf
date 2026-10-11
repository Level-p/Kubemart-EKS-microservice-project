variable "name" {
  description = "Base name for resources"
  type        = string
}

variable "cluster_name" {
  description = "EKS cluster name, used for the kubernetes.io/cluster subnet tag"
  type        = string
}

variable "all_cidr" {
  description = "CIDR block for routing (e.g., 0.0.0.0/0)"
  type        = string
  default     = "0.0.0.0/0"
}

variable "cidr" {
  description = "VPC CIDR block"
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnets" {
  description = "Map of public subnets with CIDR and AZ"
  type = map(object({
    cidr = string
    az   = string
  }))
  default = {
    pub1 = { cidr = "10.0.1.0/24", az = "eu-west-2a" }
    pub2 = { cidr = "10.0.2.0/24", az = "eu-west-2b" }
    pub3 = { cidr = "10.0.3.0/24", az = "eu-west-2c" }
  }
}

variable "private_subnets" {
  description = "Map of private subnets with CIDR and AZ (larger, because every pod gets a VPC IP)"
  type = map(object({
    cidr = string
    az   = string
  }))
  default = {
    pri1 = { cidr = "10.0.16.0/20", az = "eu-west-2a" }
    pri2 = { cidr = "10.0.32.0/20", az = "eu-west-2b" }
    pri3 = { cidr = "10.0.48.0/20", az = "eu-west-2c" }
  }
}
