# AWS access for the Kratix Promise workflows that create AWS resources, using IRSA on the
# management cluster. Each Promise gets its own ServiceAccount and IAM role. Every environment
# request lives in one namespace so each role trusts exactly one ServiceAccount.
locals {
  promise_namespace = "promise-workflows"

  management_oidc_issuer = local.management_cluster.identity[0].oidc[0].issuer
  management_oidc_host   = replace(local.management_oidc_issuer, "https://", "")

  promise_names = toset(["smtp-prod"])

  promise_role_policies = {
    "smtp-prod" = data.aws_iam_policy_document.smtp_prod.json
  }

  iam_arn_prefix = "arn:${data.aws_partition.current.partition}:iam::${var.aws_account_id}"
}

resource "kubernetes_namespace_v1" "promise_workflows" {
  provider = kubernetes.management
  metadata {
    name   = local.promise_namespace
    labels = { "demo.runtimeconditions.io/environment" = "management" }
  }
}

resource "aws_iam_openid_connect_provider" "management_cluster" {
  url            = local.management_oidc_issuer
  client_id_list = ["sts.amazonaws.com"]
}

data "aws_iam_policy_document" "promise_trust" {
  for_each = local.promise_names

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
      values   = ["system:serviceaccount:${local.promise_namespace}:${each.key}"]
    }
  }
}

# Each Promise reads and writes only its own prefix of the shared state bucket.
data "aws_iam_policy_document" "promise_state" {
  for_each = local.promise_names

  statement {
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.promise_state.arn]
    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["${each.key}/*"]
    }
  }
  statement {
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["${aws_s3_bucket.promise_state.arn}/${each.key}/*"]
  }
}

data "aws_iam_policy_document" "smtp_prod" {
  source_policy_documents = [data.aws_iam_policy_document.promise_state["smtp-prod"].json]

  # The sender and recipient identities belong to the platform (ses.tf); the Promise only checks them.
  statement {
    sid       = "ReadSesIdentities"
    actions   = ["ses:GetEmailIdentity", "ses:ListTagsForResource"]
    resources = [for identity in aws_sesv2_email_identity.notification : identity.arn]
  }
  # SMTP credentials are access keys of IAM users created under the `smtp-prod` path.
  statement {
    sid = "ManageSmtpUsers"
    actions = [
      "iam:CreateAccessKey",
      "iam:CreateUser",
      "iam:DeleteAccessKey",
      "iam:DeleteUser",
      "iam:DeleteUserPolicy",
      "iam:GetUser",
      "iam:GetUserPolicy",
      "iam:ListAccessKeys",
      "iam:ListAttachedUserPolicies",
      "iam:ListGroupsForUser",
      "iam:ListUserPolicies",
      "iam:ListUserTags",
      "iam:PutUserPolicy",
      "iam:TagUser",
      "iam:UntagUser",
    ]
    resources = ["${local.iam_arn_prefix}:user/smtp-prod/*"]
  }
}

resource "aws_iam_role" "promise" {
  for_each           = local.promise_role_policies
  name               = "promise-${each.key}"
  description        = "Assumed by the ${each.key} Kratix Promise workflows through IRSA"
  assume_role_policy = data.aws_iam_policy_document.promise_trust[each.key].json
}

resource "aws_iam_role_policy" "promise" {
  for_each = local.promise_role_policies
  name     = "promise-${each.key}"
  role     = aws_iam_role.promise[each.key].id
  policy   = each.value
}

# Kratix leaves an existing ServiceAccount unmodified, so the IRSA annotation persists.
resource "kubernetes_service_account_v1" "promise" {
  provider = kubernetes.management
  for_each = local.promise_role_policies
  metadata {
    name      = each.key
    namespace = kubernetes_namespace_v1.promise_workflows.metadata[0].name
    annotations = {
      "eks.amazonaws.com/role-arn" = aws_iam_role.promise[each.key].arn
    }
  }
}

output "promise_service_accounts" {
  description = "Namespace and ServiceAccount names for the Promises' rbac.serviceAccount, with their IAM role ARNs."
  value = {
    namespace = local.promise_namespace
    roles     = { for name, role in aws_iam_role.promise : name => role.arn }
  }
}
