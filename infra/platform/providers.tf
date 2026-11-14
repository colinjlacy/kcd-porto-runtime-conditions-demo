# Query AWS rather than persisting endpoints, CA data, or tokens in tfvars.
data "aws_eks_cluster" "existing" {
  for_each = var.cluster_names
  name     = each.value

  lifecycle {
    postcondition {
      condition     = self.status == "ACTIVE"
      error_message = "Finish the foundation apply before planning platform resources."
    }
  }
}

locals {
  # Exec credentials can refresh during longer Helm operations.
  token_args = {
    for environment, name in var.cluster_names : environment => [
      "eks", "get-token", "--cluster-name", name, "--region", var.aws_region, "--output", "json"
    ]
  }
}

provider "kubernetes" {
  alias                  = "management"
  host                   = data.aws_eks_cluster.existing["management"].endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.existing["management"].certificate_authority[0].data)
  proxy_url              = var.kubernetes_proxy_url
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = local.token_args.management
  }
}

provider "kubernetes" {
  alias                  = "dev"
  host                   = data.aws_eks_cluster.existing["dev"].endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.existing["dev"].certificate_authority[0].data)
  proxy_url              = var.kubernetes_proxy_url
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = local.token_args.dev
  }
}

provider "kubernetes" {
  alias                  = "production"
  host                   = data.aws_eks_cluster.existing["production"].endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.existing["production"].certificate_authority[0].data)
  proxy_url              = var.kubernetes_proxy_url
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = local.token_args.production
  }
}

provider "helm" {
  alias = "management"
  kubernetes = {
    host                   = data.aws_eks_cluster.existing["management"].endpoint
    cluster_ca_certificate = base64decode(data.aws_eks_cluster.existing["management"].certificate_authority[0].data)
    proxy_url              = var.kubernetes_proxy_url
    exec = {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = local.token_args.management
    }
  }
}

provider "helm" {
  alias = "dev"
  kubernetes = {
    host                   = data.aws_eks_cluster.existing["dev"].endpoint
    cluster_ca_certificate = base64decode(data.aws_eks_cluster.existing["dev"].certificate_authority[0].data)
    proxy_url              = var.kubernetes_proxy_url
    exec = {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = local.token_args.dev
    }
  }
}

provider "helm" {
  alias = "production"
  kubernetes = {
    host                   = data.aws_eks_cluster.existing["production"].endpoint
    cluster_ca_certificate = base64decode(data.aws_eks_cluster.existing["production"].certificate_authority[0].data)
    proxy_url              = var.kubernetes_proxy_url
    exec = {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = local.token_args.production
    }
  }
}

output "clusters" {
  description = "Discovered connections for the next platform stages; no authentication tokens are stored."
  value = {
    for environment, cluster in data.aws_eks_cluster.existing : environment => {
      name     = cluster.name
      arn      = cluster.arn
      endpoint = cluster.endpoint
    }
  }
}
