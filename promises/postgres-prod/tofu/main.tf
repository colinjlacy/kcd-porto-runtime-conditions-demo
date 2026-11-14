terraform {
  required_version = "= 1.12.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "= 6.73.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "= 3.7.2"
    }
  }

  # Bucket, key and region are supplied by the pipeline with -backend-config.
  backend "s3" {}
}

provider "aws" {
  region = var.aws_region
}

variable "aws_region" {
  type = string
}

variable "name" {
  description = "Identifier shared by the Aurora cluster, its instance and its subnet group; must start with pg-."
  type        = string

  validation {
    condition     = can(regex("^pg-[a-z0-9]{12}$", var.name))
    error_message = "The name must be pg- followed by 12 lowercase hex characters."
  }
}

variable "subnet_ids" {
  type = list(string)
}

variable "security_group_id" {
  type = string
}

variable "database_name" {
  type = string
}

variable "min_capacity" {
  description = "Minimum Aurora capacity units."
  type        = number
  default     = 0.5
}

variable "max_capacity" {
  description = "Maximum Aurora capacity units."
  type        = number
  default     = 2
}

variable "tags" {
  type = map(string)
}

resource "random_password" "master" {
  length  = 32
  special = false
}

resource "aws_db_subnet_group" "this" {
  name       = var.name
  subnet_ids = var.subnet_ids
  tags       = var.tags
}

resource "aws_rds_cluster" "this" {
  cluster_identifier      = var.name
  engine                  = "aurora-postgresql"
  database_name           = var.database_name
  master_username         = "app"
  master_password         = random_password.master.result
  db_subnet_group_name    = aws_db_subnet_group.this.name
  vpc_security_group_ids  = [var.security_group_id]
  storage_encrypted       = true
  backup_retention_period = 1
  skip_final_snapshot     = true
  deletion_protection     = false
  apply_immediately       = true
  tags                    = var.tags

  serverlessv2_scaling_configuration {
    min_capacity = var.min_capacity
    max_capacity = var.max_capacity
  }
}

# One writer; no reader instance and no proxy.
resource "aws_rds_cluster_instance" "writer" {
  identifier         = "${var.name}-writer"
  cluster_identifier = aws_rds_cluster.this.id
  engine             = aws_rds_cluster.this.engine
  instance_class     = "db.serverless"
  tags               = var.tags
}

output "host" {
  value = aws_rds_cluster.this.endpoint
}

output "port" {
  value = aws_rds_cluster.this.port
}

output "database_name" {
  value = aws_rds_cluster.this.database_name
}

output "username" {
  value = aws_rds_cluster.this.master_username
}

output "password" {
  value     = random_password.master.result
  sensitive = true
}
