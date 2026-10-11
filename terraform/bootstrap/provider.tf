provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project   = "kubemart"
      ManagedBy = "terraform"
      Stack     = "bootstrap"
    }
  }
}

terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # Same bucket as the main stack, different key.
  # use_lockfile = S3-native state locking (no DynamoDB table to manage)
  backend "s3" {
    bucket       = "mfon21-eks-ecommerce-tfstate"
    key          = "bootstrap/terraform.tfstate"
    region       = "eu-west-2"
    use_lockfile = true
    encrypt      = true
  }
}
