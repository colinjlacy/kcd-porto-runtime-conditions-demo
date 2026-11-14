# Everything a workload cluster needs before Kratix output can run on it: persistent volumes,
# Flux reading this environment's slice of the Kratix state bucket, and a NATS broker.
terraform {
  required_providers {
    aws        = { source = "hashicorp/aws" }
    helm       = { source = "hashicorp/helm" }
    kubernetes = { source = "hashicorp/kubernetes" }
  }
}

variable "environment" {
  description = "Environment name; also the Kratix Destination name and state bucket prefix."
  type        = string
}

variable "cluster" {
  description = "The existing EKS cluster (aws_eks_cluster data source)."
  type = object({
    name    = string
    version = string
    oidc    = string
  })
}

variable "aws_region" {
  type = string
}

variable "state_bucket" {
  description = "Bucket Kratix writes rendered manifests to."
  type = object({
    id  = string
    arn = string
  })
}

variable "chart_versions" {
  type = object({
    flux = string
    nats = string
  })
}

variable "helm_timeout_seconds" {
  type = number
}

locals {
  oidc_host = replace(var.cluster.oidc, "https://", "")
}

resource "aws_iam_openid_connect_provider" "cluster" {
  url            = var.cluster.oidc
  client_id_list = ["sts.amazonaws.com"]
}

data "aws_iam_policy_document" "irsa_trust" {
  for_each = {
    ebs_csi = "kube-system:ebs-csi-controller-sa"
    flux    = "flux-system:source-controller"
  }

  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.cluster.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:sub"
      values   = ["system:serviceaccount:${each.value}"]
    }
  }
}

# Persistent volumes.
resource "aws_iam_role" "ebs_csi" {
  name               = "${var.cluster.name}-ebs-csi"
  assume_role_policy = data.aws_iam_policy_document.irsa_trust["ebs_csi"].json
}

resource "aws_iam_role_policy_attachment" "ebs_csi" {
  role       = aws_iam_role.ebs_csi.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

data "aws_eks_addon_version" "ebs_csi" {
  addon_name         = "aws-ebs-csi-driver"
  kubernetes_version = var.cluster.version
}

resource "aws_eks_addon" "ebs_csi" {
  cluster_name             = var.cluster.name
  addon_name               = "aws-ebs-csi-driver"
  addon_version            = data.aws_eks_addon_version.ebs_csi.version
  service_account_role_arn = aws_iam_role.ebs_csi.arn

  depends_on = [aws_iam_role_policy_attachment.ebs_csi]
}

resource "kubernetes_storage_class_v1" "gp3" {
  metadata {
    name        = "gp3"
    annotations = { "storageclass.kubernetes.io/is-default-class" = "true" }
  }
  storage_provisioner    = "ebs.csi.aws.com"
  volume_binding_mode    = "WaitForFirstConsumer"
  allow_volume_expansion = true
  parameters             = { type = "gp3", encrypted = "true" }

  depends_on = [aws_eks_addon.ebs_csi]
}

# Flux may list the bucket (S3 returns 403 instead of 404 for missing keys such as Flux's optional
# root .sourceignore without it), but it can read only this environment's objects.
data "aws_iam_policy_document" "flux_read" {
  statement {
    actions   = ["s3:ListBucket"]
    resources = [var.state_bucket.arn]
  }
  statement {
    actions   = ["s3:GetObject"]
    resources = ["${var.state_bucket.arn}/${var.environment}/*", "${var.state_bucket.arn}/.sourceignore"]
  }
}

resource "aws_iam_role" "flux" {
  name               = "${var.cluster.name}-flux-source"
  assume_role_policy = data.aws_iam_policy_document.irsa_trust["flux"].json
}

resource "aws_iam_role_policy" "flux" {
  name   = "read-state-bucket"
  role   = aws_iam_role.flux.id
  policy = data.aws_iam_policy_document.flux_read.json
}

resource "helm_release" "flux" {
  name             = "flux"
  namespace        = "flux-system"
  create_namespace = true
  repository       = "https://fluxcd-community.github.io/helm-charts"
  chart            = "flux2"
  version          = var.chart_versions.flux
  values = [yamlencode({
    # Only the source and kustomize controllers are needed to apply bucket contents.
    helmController            = { create = false }
    imageAutomationController = { create = false }
    imageReflectionController = { create = false }
    notificationController    = { create = false }
    sourceController = {
      serviceAccount = { annotations = { "eks.amazonaws.com/role-arn" = aws_iam_role.flux.arn } }
    }
  })]
  atomic          = true
  cleanup_on_fail = true
  wait            = true
  timeout         = var.helm_timeout_seconds
}

# Installed separately so the Flux CRDs exist before Helm resolves the Flux resource kinds.
resource "helm_release" "flux_config" {
  name            = "flux-config"
  namespace       = "flux-system"
  chart           = "${path.module}/flux-config"
  atomic          = true
  cleanup_on_fail = true
  timeout         = var.helm_timeout_seconds
  values = [yamlencode({
    environment = var.environment
    bucketName  = var.state_bucket.id
    region      = var.aws_region
  })]

  depends_on = [helm_release.flux]
}

resource "helm_release" "nats" {
  name             = "nats"
  namespace        = "nats"
  create_namespace = true
  repository       = "https://nats-io.github.io/k8s/helm/charts/"
  chart            = "nats"
  version          = var.chart_versions.nats
  values = [yamlencode({
    config = {
      cluster = { enabled = false }
      jetstream = {
        enabled   = true
        fileStore = { pvc = { enabled = true, size = "5Gi" } }
      }
    }
    natsBox = { enabled = false }
  })]
  atomic          = true
  cleanup_on_fail = true
  wait            = true
  timeout         = var.helm_timeout_seconds

  depends_on = [kubernetes_storage_class_v1.gp3]
}
