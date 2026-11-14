# The watcher turns each RuntimeConditionsProfile into Kratix requests in the promise namespace.
# It runs on the management cluster and holds no AWS credentials.
locals {
  watcher_name  = "rcprofile-watcher"
  watcher_image = "ghcr.io/${lower(var.github_repository)}/watcher:latest"

  # API groups and plural resource names of the Kratix request kinds the watcher manages.
  watcher_request_groups = {
    "platform.runtimeconditions.io"            = ["workloads"]
    "dev.platform.runtimeconditions.io"        = ["postgresdatabases", "natsstreams", "emailsenders"]
    "production.platform.runtimeconditions.io" = ["postgresdatabases", "natsstreams", "emailsenders"]
  }

  # Images of the readiness checks the watcher adds to workloads.
  watcher_check_images = {
    POSTGRES_CLIENT_IMAGE = "postgres:17-alpine"
    CURL_IMAGE            = "curlimages/curl:8.11.1"
    NATS_BOX_IMAGE        = "natsio/nats-box:0.14.5"
  }
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
  dynamic "rule" {
    for_each = local.watcher_request_groups
    content {
      api_groups = [rule.key]
      resources  = rule.value
      verbs      = ["get", "list", "watch", "create", "patch", "delete"]
    }
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
          dynamic "env" {
            for_each = local.watcher_check_images
            content {
              name  = env.key
              value = env.value
            }
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
