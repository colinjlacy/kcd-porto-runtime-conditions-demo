# The watcher turns each RuntimeConditionsProfile into Kratix requests in the promise namespace.
# It runs on the management cluster and holds no AWS credentials.
locals {
  watcher_name  = "rcprofile-watcher"
  watcher_image = "ghcr.io/${lower(var.github_repository)}/watcher:latest"

  # Plural resource names of the Kratix request kinds the watcher manages.
  watcher_request_resources = [
    "applications",
    "devpostgreses", "devnatses", "devsmtps",
    "prodpostgreses", "prodnatses", "prodsmtps",
  ]
}

resource "kubernetes_namespace_v1" "watcher" {
  provider = kubernetes.management
  metadata {
    name   = local.watcher_name
    labels = { "demo.runtimeconditions.io/environment" = "management" }
  }
}

resource "kubernetes_service_account_v1" "watcher" {
  provider = kubernetes.management
  metadata {
    name      = local.watcher_name
    namespace = kubernetes_namespace_v1.watcher.metadata[0].name
  }
  automount_service_account_token = true
}

resource "kubernetes_cluster_role_v1" "watcher" {
  provider = kubernetes.management
  metadata {
    name = local.watcher_name
  }
  rule {
    api_groups = ["runtimeconditions.io"]
    resources  = ["runtimeconditionsprofiles"]
    verbs      = ["get", "list", "watch"]
  }
  rule {
    api_groups = [""]
    resources  = ["events"]
    verbs      = ["create"]
  }

  depends_on = [helm_release.rcprofile_crd]
}

resource "kubernetes_cluster_role_binding_v1" "watcher" {
  provider = kubernetes.management
  metadata {
    name = local.watcher_name
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role_v1.watcher.metadata[0].name
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.watcher.metadata[0].name
    namespace = kubernetes_namespace_v1.watcher.metadata[0].name
  }
}

resource "kubernetes_role_v1" "watcher_requests" {
  provider = kubernetes.management
  metadata {
    name      = local.watcher_name
    namespace = kubernetes_namespace_v1.promise_workflows.metadata[0].name
  }
  rule {
    api_groups = ["platform.runtimeconditions.io"]
    resources  = local.watcher_request_resources
    verbs      = ["get", "list", "watch", "create", "patch", "delete"]
  }
}

resource "kubernetes_role_binding_v1" "watcher_requests" {
  provider = kubernetes.management
  metadata {
    name      = local.watcher_name
    namespace = kubernetes_namespace_v1.promise_workflows.metadata[0].name
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role_v1.watcher_requests.metadata[0].name
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.watcher.metadata[0].name
    namespace = kubernetes_namespace_v1.watcher.metadata[0].name
  }
}

resource "kubernetes_deployment_v1" "watcher" {
  provider = kubernetes.management
  metadata {
    name      = local.watcher_name
    namespace = kubernetes_namespace_v1.watcher.metadata[0].name
    labels    = { "app.kubernetes.io/name" = local.watcher_name }
  }

  spec {
    # One replica: the watcher serializes its work and is not leader-elected.
    replicas = 1
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = { "app.kubernetes.io/name" = local.watcher_name }
    }

    template {
      metadata {
        labels = { "app.kubernetes.io/name" = local.watcher_name }
      }
      spec {
        service_account_name = kubernetes_service_account_v1.watcher.metadata[0].name

        container {
          name              = "watcher"
          image             = local.watcher_image
          image_pull_policy = "Always"

          env {
            name  = "REQUEST_NAMESPACE"
            value = kubernetes_namespace_v1.promise_workflows.metadata[0].name
          }
          env {
            name  = "SMTP_FROM_ADDRESS"
            value = var.notification_from_address
          }
          env {
            name  = "SMTP_TO_ADDRESS"
            value = var.notification_to_address
          }

          resources {
            requests = { cpu = "50m", memory = "128Mi" }
            limits   = { memory = "256Mi" }
          }

          security_context {
            run_as_non_root            = true
            run_as_user                = 1000
            read_only_root_filesystem  = true
            allow_privilege_escalation = false
            capabilities {
              drop = ["ALL"]
            }
          }
        }
      }
    }
  }
}
