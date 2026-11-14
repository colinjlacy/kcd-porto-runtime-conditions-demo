# Lets the build pipeline submit RCProfiles: a GitHub OIDC role that can only invoke one
# VPC-attached Lambda, which in turn may only create and patch profiles in one namespace.
data "aws_partition" "current" {}

locals {
  publisher_name     = "rcprofile-publisher"
  publisher_group    = "rcprofile-publishers"
  management_cluster = data.aws_eks_cluster.existing["management"]
  github_oidc_url    = "https://token.actions.githubusercontent.com"
  github_oidc_arn = (
    var.create_github_oidc_provider
    ? aws_iam_openid_connect_provider.github[0].arn
    : data.aws_iam_openid_connect_provider.github[0].arn
  )
}

# An AWS account can hold one provider per issuer URL; reuse it when another stack created it.
resource "aws_iam_openid_connect_provider" "github" {
  count          = var.create_github_oidc_provider ? 1 : 0
  url            = local.github_oidc_url
  client_id_list = ["sts.amazonaws.com"]
}

data "aws_iam_openid_connect_provider" "github" {
  count = var.create_github_oidc_provider ? 0 : 1
  url   = local.github_oidc_url
}

data "aws_iam_policy_document" "github_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [local.github_oidc_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    # Exactly one repository and branch; forks and other branches cannot assume the role.
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_repository}:ref:refs/heads/${var.github_deployment_branch}"]
    }
  }
}

resource "aws_iam_role" "github_publisher" {
  name               = "${local.publisher_name}-github"
  description        = "Assumed by ${var.github_repository} on ${var.github_deployment_branch} to submit RCProfiles"
  assume_role_policy = data.aws_iam_policy_document.github_trust.json
}

data "aws_iam_policy_document" "invoke_publisher" {
  statement {
    actions   = ["lambda:InvokeFunction"]
    resources = [aws_lambda_function.publisher.arn]
  }
}

resource "aws_iam_role_policy" "github_invoke" {
  name   = "invoke-profile-publisher"
  role   = aws_iam_role.github_publisher.id
  policy = data.aws_iam_policy_document.invoke_publisher.json
}

data "aws_iam_policy_document" "lambda_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "publisher_function" {
  name               = "${local.publisher_name}-function"
  description        = "Execution role of the RCProfile publisher; also its identity on the management cluster"
  assume_role_policy = data.aws_iam_policy_document.lambda_trust.json
}

# Network interfaces in the VPC and log delivery; no other AWS permissions are needed.
resource "aws_iam_role_policy_attachment" "publisher_vpc_access" {
  role       = aws_iam_role.publisher_function.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

resource "aws_cloudwatch_log_group" "publisher" {
  name              = "/aws/lambda/${local.publisher_name}"
  retention_in_days = 30
}

data "archive_file" "publisher" {
  type        = "zip"
  source_file = "${path.module}/lambda/apply_profile.py"
  output_path = "${path.module}/.terraform/${local.publisher_name}.zip"
}

resource "aws_lambda_function" "publisher" {
  function_name    = local.publisher_name
  description      = "Applies a generated RCProfile to the management cluster"
  role             = aws_iam_role.publisher_function.arn
  runtime          = "python3.13"
  handler          = "apply_profile.handler"
  filename         = data.archive_file.publisher.output_path
  source_code_hash = data.archive_file.publisher.output_base64sha256
  timeout          = 30
  memory_size      = 256

  # The cluster's private API is only reachable from inside its VPC. Endpoint and CA come from
  # this configuration so the function never needs to call the EKS API itself.
  vpc_config {
    subnet_ids         = local.management_cluster.vpc_config[0].subnet_ids
    security_group_ids = [var.publisher_security_group_id]
  }

  environment {
    variables = {
      CLUSTER_NAME      = local.management_cluster.name
      CLUSTER_ENDPOINT  = local.management_cluster.endpoint
      CLUSTER_CA_DATA   = local.management_cluster.certificate_authority[0].data
      PROFILE_NAMESPACE = kubernetes_namespace_v1.profiles.metadata[0].name
    }
  }

  depends_on = [aws_cloudwatch_log_group.publisher, aws_iam_role_policy_attachment.publisher_vpc_access]
}

# Kubernetes identity: the function's role maps to a group that may touch only RCProfiles
# in the profile namespace.
resource "aws_eks_access_entry" "publisher" {
  cluster_name      = local.management_cluster.name
  principal_arn     = aws_iam_role.publisher_function.arn
  type              = "STANDARD"
  kubernetes_groups = [local.publisher_group]
}

resource "kubernetes_role_v1" "profile_publisher" {
  provider = kubernetes.management
  metadata {
    name      = local.publisher_name
    namespace = kubernetes_namespace_v1.profiles.metadata[0].name
  }
  rule {
    api_groups = ["runtimeconditions.io"]
    resources  = ["runtimeconditionsprofiles"]
    verbs      = ["get", "create", "patch"]
  }

  depends_on = [helm_release.rcprofile_crd]
}

resource "kubernetes_role_binding_v1" "profile_publisher" {
  provider = kubernetes.management
  metadata {
    name      = local.publisher_name
    namespace = kubernetes_namespace_v1.profiles.metadata[0].name
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role_v1.profile_publisher.metadata[0].name
  }
  subject {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Group"
    name      = local.publisher_group
  }
}

output "github_actions" {
  description = "Values for the repository's Actions variables: PUBLISHER_ROLE_ARN, PUBLISHER_FUNCTION_NAME, AWS_REGION."
  value = {
    PUBLISHER_ROLE_ARN      = aws_iam_role.github_publisher.arn
    PUBLISHER_FUNCTION_NAME = aws_lambda_function.publisher.function_name
    AWS_REGION              = var.aws_region
  }
}
