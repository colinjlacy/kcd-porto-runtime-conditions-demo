# Delivery path for Kratix output: Kratix (management cluster) writes manifests to this bucket
# and Flux on each workload cluster reads them. Both sides authenticate with IRSA.
locals {
  workload_environments  = ["dev", "production"]
  kratix_state_bucket    = "shipment-demo-kratix-state-${var.aws_account_id}-${var.aws_region}"
  kratix_namespace       = "kratix-platform-system"
  kratix_service_account = "kratix-platform-controller-manager"
}

resource "aws_s3_bucket" "kratix_state" {
  bucket = local.kratix_state_bucket
}

resource "aws_s3_bucket_public_access_block" "kratix_state" {
  bucket                  = aws_s3_bucket.kratix_state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Rendered manifests include generated credentials, so every object is encrypted.
resource "aws_s3_bucket_server_side_encryption_configuration" "kratix_state" {
  bucket = aws_s3_bucket.kratix_state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

data "aws_iam_policy_document" "kratix_state_tls_only" {
  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.kratix_state.arn, "${aws_s3_bucket.kratix_state.arn}/*"]
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

resource "aws_s3_bucket_policy" "kratix_state" {
  bucket = aws_s3_bucket.kratix_state.id
  policy = data.aws_iam_policy_document.kratix_state_tls_only.json

  depends_on = [aws_s3_bucket_public_access_block.kratix_state]
}

data "aws_iam_policy_document" "kratix_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.management_cluster.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.management_oidc_host}:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.management_oidc_host}:sub"
      values   = ["system:serviceaccount:${local.kratix_namespace}:${local.kratix_service_account}"]
    }
  }
}

data "aws_iam_policy_document" "kratix_state_write" {
  statement {
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.kratix_state.arn]
  }
  statement {
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["${aws_s3_bucket.kratix_state.arn}/*"]
  }
}

resource "aws_iam_role" "kratix" {
  name               = "kratix-controller"
  description        = "Assumed by the Kratix controller through IRSA to write the state store"
  assume_role_policy = data.aws_iam_policy_document.kratix_trust.json
}

resource "aws_iam_role_policy" "kratix" {
  name   = "write-state-store"
  role   = aws_iam_role.kratix.id
  policy = data.aws_iam_policy_document.kratix_state_write.json
}

module "workload_dev" {
  source = "./modules/workload"
  providers = {
    aws        = aws
    helm       = helm.dev
    kubernetes = kubernetes.dev
  }

  environment = "dev"
  cluster = {
    name    = data.aws_eks_cluster.existing["dev"].name
    version = data.aws_eks_cluster.existing["dev"].version
    oidc    = data.aws_eks_cluster.existing["dev"].identity[0].oidc[0].issuer
  }
  aws_region           = var.aws_region
  state_bucket         = { id = aws_s3_bucket.kratix_state.id, arn = aws_s3_bucket.kratix_state.arn }
  chart_versions       = var.workload_chart_versions
  helm_timeout_seconds = var.helm_timeout_seconds
}

module "workload_production" {
  source = "./modules/workload"
  providers = {
    aws        = aws
    helm       = helm.production
    kubernetes = kubernetes.production
  }

  environment = "production"
  cluster = {
    name    = data.aws_eks_cluster.existing["production"].name
    version = data.aws_eks_cluster.existing["production"].version
    oidc    = data.aws_eks_cluster.existing["production"].identity[0].oidc[0].issuer
  }
  aws_region           = var.aws_region
  state_bucket         = { id = aws_s3_bucket.kratix_state.id, arn = aws_s3_bucket.kratix_state.arn }
  chart_versions       = var.workload_chart_versions
  helm_timeout_seconds = var.helm_timeout_seconds
}
