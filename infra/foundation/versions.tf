# Configure remote state before applying this foundation. Credentials come
# from the standard AWS credential chain, never from committed variables.
terraform {
  required_version = "= 1.12.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "= 6.73.0"
    }
  }
}

provider "aws" {
  region              = var.aws_region
  allowed_account_ids = [var.aws_account_id]

  default_tags {
    tags = {
      Project   = var.name_prefix
      ManagedBy = "OpenTofu"
    }
  }
}
