# One Aurora Serverless v2 PostgreSQL cluster shared by every production profile. It is built
# here, ahead of any request, so the postgres-prod Promise only has to create a database and a
# login on it. The cluster pauses when idle and resumes on the next connection.
locals {
  shared_postgres_name = "${local.publisher_name}-shared-postgres"
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
  backup_retention_period = 1
  skip_final_snapshot     = true
  apply_immediately       = true

  serverlessv2_scaling_configuration {
    min_capacity             = 0
    max_capacity             = 2
    seconds_until_auto_pause = 300
  }
}

resource "aws_rds_cluster_instance" "shared_postgres_writer" {
  identifier         = "${local.shared_postgres_name}-writer"
  cluster_identifier = aws_rds_cluster.shared_postgres.id
  engine             = aws_rds_cluster.shared_postgres.engine
  instance_class     = "db.serverless"
}

# Read by the postgres-prod Promise workflow to create a database and login per profile.
resource "kubernetes_secret_v1" "shared_postgres_admin" {
  provider = kubernetes.management
  metadata {
    name      = "shared-postgres"
    namespace = kubernetes_namespace_v1.promise_workflows.metadata[0].name
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
  description = "Endpoint of the shared production Aurora cluster and the management-cluster Secret that holds its admin login."
  value = {
    endpoint = aws_rds_cluster.shared_postgres.endpoint
    secret   = "${kubernetes_secret_v1.shared_postgres_admin.metadata[0].namespace}/${kubernetes_secret_v1.shared_postgres_admin.metadata[0].name}"
  }
}
