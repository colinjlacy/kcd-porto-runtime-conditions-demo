removed {
  from = kubernetes_manifest.rcprofile_crd
  lifecycle {
    # Preserve the existing CRD and all profiles when migrating to Helm.
    destroy = false
  }
}

resource "helm_release" "rcprofile_crd" {
  provider        = helm.management
  name            = "runtime-conditions-crd"
  namespace       = kubernetes_namespace_v1.profiles.metadata[0].name
  repository      = "oci://ghcr.io/runtimeconditions/charts"
  chart           = "runtime-conditions-crd"
  version         = var.chart_versions.rcprofile_crd
  skip_crds       = false
  atomic          = true
  cleanup_on_fail = true
  wait            = true
  timeout         = var.helm_timeout_seconds
}

resource "kubernetes_namespace_v1" "profiles" {
  provider = kubernetes.management
  metadata {
    name   = var.namespaces.profiles
    labels = { "demo.runtimeconditions.io/environment" = "management" }
  }
}

resource "kubernetes_namespace_v1" "dev_support" {
  provider = kubernetes.dev
  metadata {
    name   = var.namespaces.workload_support
    labels = { "demo.runtimeconditions.io/environment" = "dev" }
  }
}

resource "kubernetes_namespace_v1" "production_support" {
  provider = kubernetes.production
  metadata {
    name   = var.namespaces.workload_support
    labels = { "demo.runtimeconditions.io/environment" = "production" }
  }
}

resource "helm_release" "cert_manager" {
  provider         = helm.management
  name             = "cert-manager"
  namespace        = "cert-manager"
  create_namespace = true
  repository       = "https://charts.jetstack.io"
  chart            = "cert-manager"
  version          = var.chart_versions.cert_manager
  values           = [yamlencode({ crds = { enabled = true } })]
  atomic           = true
  cleanup_on_fail  = true
  wait             = true
  wait_for_jobs    = true
  timeout          = var.helm_timeout_seconds
}

resource "helm_release" "kratix" {
  provider = helm.management
  name     = "kratix"
  # The chart creates and owns kratix-platform-system; Helm keeps its release record elsewhere.
  namespace        = "default"
  create_namespace = false
  repository       = "https://syntasso.github.io/helm-charts"
  chart            = "kratix"
  version          = var.chart_versions.kratix
  values = [yamlencode({
    # The upstream chart's sample SeaweedFS store and credentials stay disabled.
    stateStores  = []
    destinations = []
    serviceAccount = {
      name        = local.kratix_service_account
      annotations = { "eks.amazonaws.com/role-arn" = aws_iam_role.kratix.arn }
    }
    additionalResources = concat(
      [{
        apiVersion = "platform.kratix.io/v1alpha1"
        kind       = "BucketStateStore"
        metadata   = { name = "default" }
        spec = {
          bucketName = aws_s3_bucket.kratix_state.id
          endpoint   = "s3.${var.aws_region}.amazonaws.com"
          authMethod = "IAM"
          insecure   = false
        }
      }],
      [for environment in local.workload_environments : {
        apiVersion = "platform.kratix.io/v1alpha1"
        kind       = "Destination"
        metadata   = { name = environment, labels = { environment = environment } }
        spec = {
          path          = environment
          stateStoreRef = { name = "default", kind = "BucketStateStore" }
        }
      }]
    )
  })]
  atomic          = true
  cleanup_on_fail = true
  wait            = true
  wait_for_jobs   = true
  timeout         = var.helm_timeout_seconds

  depends_on = [helm_release.cert_manager]
}

output "namespaces" {
  description = "Namespaces created for profile submission and later environment integrations."
  value = {
    profiles           = kubernetes_namespace_v1.profiles.metadata[0].name
    dev_support        = kubernetes_namespace_v1.dev_support.metadata[0].name
    production_support = kubernetes_namespace_v1.production_support.metadata[0].name
  }
}
