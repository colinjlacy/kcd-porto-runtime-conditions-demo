resource "kubernetes_manifest" "rcprofile_crd" {
  provider = kubernetes.management
  manifest = yamldecode(file(var.rcprofile_crd_file))

  field_manager {
    name            = "shipment-demo-platform"
    force_conflicts = false
  }
  wait {
    condition {
      type   = "Established"
      status = "True"
    }
  }
}

resource "kubernetes_namespace_v1" "profiles" {
  provider = kubernetes.management
  metadata {
    name   = var.namespaces.profiles
    labels = { "demo.runtimeconditions.io/environment" = "management" }
  }

  depends_on = [kubernetes_manifest.rcprofile_crd]
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
  provider         = helm.management
  name             = "kratix"
  namespace        = "kratix-platform-system"
  create_namespace = true
  repository       = "https://syntasso.github.io/helm-charts"
  chart            = "kratix"
  version          = var.chart_versions.kratix
  values = [yamlencode({
    # The upstream chart includes a sample SeaweedFS store and credentials.
    # State store and destination ownership belong to the later delivery stage.
    stateStores         = []
    destinations        = []
    additionalResources = []
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
