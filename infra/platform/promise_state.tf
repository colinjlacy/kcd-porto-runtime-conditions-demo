# Backend for the OpenTofu state written by the Kratix Promise workflows, and the shared AWS
# settings those workflows read. Network values match what the profile publisher already uses.
locals {
  promise_state_bucket = "shipment-demo-promise-state-${var.aws_account_id}-${var.aws_region}"
}

resource "aws_s3_bucket" "promise_state" {
  bucket = local.promise_state_bucket
}

resource "aws_s3_bucket_public_access_block" "promise_state" {
  bucket                  = aws_s3_bucket.promise_state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# State files hold generated credentials, so every object is encrypted and old versions are kept.
resource "aws_s3_bucket_server_side_encryption_configuration" "promise_state" {
  bucket = aws_s3_bucket.promise_state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_versioning" "promise_state" {
  bucket = aws_s3_bucket.promise_state.id
  versioning_configuration {
    status = "Enabled"
  }
}

data "aws_iam_policy_document" "promise_state_tls_only" {
  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.promise_state.arn, "${aws_s3_bucket.promise_state.arn}/*"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "promise_state" {
  bucket = aws_s3_bucket.promise_state.id
  policy = data.aws_iam_policy_document.promise_state_tls_only.json

  depends_on = [aws_s3_bucket_public_access_block.promise_state]
}

# Read by Promise workflows that create AWS resources (for example postgres-prod).
resource "kubernetes_config_map_v1" "promise_aws_config" {
  provider = kubernetes.management
  metadata {
    name      = "promise-aws-config"
    namespace = kubernetes_namespace_v1.promise_workflows.metadata[0].name
  }
  data = {
    AWS_REGION        = var.aws_region
    STATE_BUCKET      = aws_s3_bucket.promise_state.id
    VPC_ID            = local.management_cluster.vpc_config[0].vpc_id
    SUBNET_IDS        = join(",", sort(tolist(local.management_cluster.vpc_config[0].subnet_ids)))
    SECURITY_GROUP_ID = var.publisher_security_group_id
  }
}

output "promise_state" {
  description = "Bucket holding Promise workflow state and the ConfigMap that exposes it with the AWS network settings."
  value = {
    bucket     = aws_s3_bucket.promise_state.id
    config_map = "${kubernetes_config_map_v1.promise_aws_config.metadata[0].namespace}/${kubernetes_config_map_v1.promise_aws_config.metadata[0].name}"
  }
}
