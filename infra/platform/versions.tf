terraform {
  required_version = "= 1.12.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "= 6.73.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "= 3.5.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "= 2.8.1"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "= 3.3.0"
    }
  }
}

# This root has its own state and runs only after foundation has completed.
# Credentials for both providers and the AWS CLI use the operator's environment.
provider "aws" {
  region              = var.aws_region
  allowed_account_ids = [var.aws_account_id]
}
