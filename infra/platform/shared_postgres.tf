# One Aurora Serverless v2 PostgreSQL cluster shared by every production profile. It is built
# here, ahead of any request, so the postgres-prod Promise only has to create a database and a
# login on it. It never pauses, so the first event after an idle period is not delayed by a resume.
locals {
  shared_postgres_name = "${local.publisher_name}-shared-postgres"
}

# The admin login lives in its own namespace so only the postgres-prod workflow is granted
# access to it; the namespace that holds Promise requests is readable by every Promise workflow.
resource "kubernetes_namespace_v1" "database_admin" {
  provider = kubernetes.management
  metadata {
    name   = "platform-database"
    labels = { "demo.runtimeconditions.io/environment" = "management" }
  }
}

resource "random_password" "shared_postgres_admin" {
  length  = 32
  special = false
}

resource "aws_db_subnet_group" "shared_postgres" {
  name       = local.shared_postgres_name
  subnet_ids = sort(tolist(local.management_cluster.vpc_config[0].subnet_ids))
}

resource "aws_rds_cluster" "shared_postgres" {
  cluster_identifier      = local.shared_postgres_name
  engine                  = "aurora-postgresql"
  master_username         = "admin_app"
  master_password         = random_password.shared_postgres_admin.result
  db_subnet_group_name    = aws_db_subnet_group.shared_postgres.name
  vpc_security_group_ids  = [var.publisher_security_group_id]
  storage_encrypted       = true
  enable_http_endpoint    = true
  backup_retention_period = 1
  skip_final_snapshot     = true
  apply_immediately       = true

  serverlessv2_scaling_configuration {
    min_capacity = 0.5
    max_capacity = 2
  }
}

resource "aws_rds_cluster_instance" "shared_postgres_writer" {
  identifier         = "${local.shared_postgres_name}-writer"
  cluster_identifier = aws_rds_cluster.shared_postgres.id
  engine             = aws_rds_cluster.shared_postgres.engine
  instance_class     = "db.serverless"
}

# Data API uses the same admin login as the Promise workflow. No password rotation is enabled.
# A unique name avoids collisions with secrets pending deletion between full platform rebuilds.
resource "aws_secretsmanager_secret" "shared_postgres_admin" {
  name_prefix = "${local.shared_postgres_name}-admin-"
  description = "Shared Aurora admin credentials for the demo's RDS Data API checks."
}

resource "aws_secretsmanager_secret_version" "shared_postgres_admin" {
  secret_id = aws_secretsmanager_secret.shared_postgres_admin.id
  secret_string = jsonencode({
    engine              = "postgres"
    host                = aws_rds_cluster.shared_postgres.endpoint
    port                = aws_rds_cluster.shared_postgres.port
    dbname              = "postgres"
    dbClusterIdentifier = aws_rds_cluster.shared_postgres.cluster_identifier
    username            = aws_rds_cluster.shared_postgres.master_username
    password            = random_password.shared_postgres_admin.result
  })

  depends_on = [aws_rds_cluster_instance.shared_postgres_writer]
}

# Read by the postgres-prod Promise workflow to create a database and login per profile.
resource "kubernetes_secret_v1" "shared_postgres_admin" {
  provider = kubernetes.management
  metadata {
    name      = "shared-postgres"
    namespace = kubernetes_namespace_v1.database_admin.metadata[0].name
  }
  data = {
    host     = aws_rds_cluster.shared_postgres.endpoint
    port     = tostring(aws_rds_cluster.shared_postgres.port)
    username = aws_rds_cluster.shared_postgres.master_username
    password = random_password.shared_postgres_admin.result
  }

  depends_on = [aws_rds_cluster_instance.shared_postgres_writer]
}

output "shared_postgres" {
  description = "Shared Aurora endpoint, Kubernetes admin Secret, and non-secret identifiers for RDS Data API checks."
  value = {
    endpoint         = aws_rds_cluster.shared_postgres.endpoint
    secret           = "${kubernetes_secret_v1.shared_postgres_admin.metadata[0].namespace}/${kubernetes_secret_v1.shared_postgres_admin.metadata[0].name}"
    cluster_arn      = aws_rds_cluster.shared_postgres.arn
    admin_secret_arn = aws_secretsmanager_secret_version.shared_postgres_admin.secret_arn
    region           = var.aws_region
  }
}
