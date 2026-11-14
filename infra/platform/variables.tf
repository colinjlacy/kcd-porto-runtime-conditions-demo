variable "aws_account_id" {
  description = "AWS account containing the existing clusters; prevents targeting a different account."
  type        = string
  nullable    = false

  validation {
    condition     = can(regex("^[0-9]{12}$", var.aws_account_id))
    error_message = "Supply the 12-digit AWS account ID."
  }
}

variable "aws_region" {
  description = "AWS region containing the three existing EKS clusters."
  type        = string
  nullable    = false

  validation {
    condition     = can(regex("^[a-z]{2}(-[a-z]+)+-[0-9]+$", var.aws_region))
    error_message = "Supply an AWS region name."
  }
}

variable "cluster_names" {
  description = "Existing EKS cluster names, keyed by management, dev, and production."
  type        = map(string)
  nullable    = false

  validation {
    condition = (
      toset(keys(var.cluster_names)) == toset(["management", "dev", "production"]) &&
      length(toset(values(var.cluster_names))) == 3 &&
      alltrue([for name in values(var.cluster_names) : can(regex("^[A-Za-z0-9][A-Za-z0-9_-]{0,99}$", name))])
    )
    error_message = "Supply distinct valid EKS names for management, dev, and production."
  }
}

variable "chart_versions" {
  description = "Explicit Helm chart version pins; these are chart versions, not application versions."
  type = object({
    cert_manager  = string
    kratix        = string
    rcprofile_crd = optional(string, "0.1.1")
  })
  default = {
    cert_manager  = "v1.21.3"
    kratix        = "v0.0.1"
    rcprofile_crd = "0.1.1"
  }
  nullable = false

  validation {
    condition = alltrue([
      for version in values(var.chart_versions) :
      can(regex("^v?[0-9]+\\.[0-9]+\\.[0-9]+(-[0-9A-Za-z.-]+)?(\\+[0-9A-Za-z.-]+)?$", version))
    ])
    error_message = "Pin exact cert-manager, Kratix, and RCProfile CRD chart versions; ranges and latest are not accepted."
  }
}

variable "namespaces" {
  description = "Namespace for management RCProfiles and separate support namespaces in the workload clusters."
  type = object({
    profiles         = string
    workload_support = string
  })
  default = {
    profiles         = "runtime-conditions"
    workload_support = "application-support"
  }
  nullable = false

  validation {
    condition = alltrue([
      for name in values(var.namespaces) :
      length(name) <= 63 && can(regex("^[a-z0-9]([a-z0-9-]*[a-z0-9])?$", name))
    ])
    error_message = "Namespace names must be lowercase DNS labels of at most 63 characters."
  }
}

variable "kubernetes_proxy_url" {
  description = "Optional existing HTTP/SOCKS proxy for Kubernetes API access; it does not create a network route."
  type        = string
  default     = null
}

variable "helm_timeout_seconds" {
  description = "Maximum wait for each Helm installation or upgrade."
  type        = number
  default     = 600
  nullable    = false

  validation {
    condition     = var.helm_timeout_seconds > 0 && var.helm_timeout_seconds == floor(var.helm_timeout_seconds)
    error_message = "Use a positive whole number of seconds."
  }
}

variable "github_repository" {
  description = "GitHub repository (owner/name) whose workflow may submit profiles."
  type        = string
  nullable    = false

  validation {
    condition     = can(regex("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", var.github_repository))
    error_message = "Use the owner/name form, for example my-org/shipment-notification-demo."
  }
}

variable "github_oidc_subject_repository" {
  description = "The repository exactly as it appears in the workflow token's sub claim: owner/name, or owner@ownerID/name@repoID when GitHub issues immutable-ID subjects."
  type        = string
  nullable    = false

  validation {
    condition     = can(regex("^[A-Za-z0-9_.-]+(@[0-9]+)?/[A-Za-z0-9_.-]+(@[0-9]+)?$", var.github_oidc_subject_repository))
    error_message = "Use owner/name or owner@ownerID/name@repoID."
  }
}

variable "github_deployment_branch" {
  description = "Branch whose workflow runs may assume the publisher role."
  type        = string
  default     = "main"
  nullable    = false

  validation {
    condition     = can(regex("^[A-Za-z0-9._/-]+$", var.github_deployment_branch))
    error_message = "Use one literal branch name; wildcards are not accepted."
  }
}

variable "create_github_oidc_provider" {
  description = "Create the account's GitHub Actions OIDC provider. Set false if the account already has one."
  type        = bool
  default     = true
  nullable    = false
}

variable "publisher_security_group_id" {
  description = "Security group for the publisher Lambda; foundation lets it reach the management API on 443."
  type        = string
  nullable    = false

  validation {
    condition     = can(regex("^sg-[0-9a-f]+$", var.publisher_security_group_id))
    error_message = "Supply a security group ID such as sg-0123456789abcdef0."
  }
}

variable "workload_chart_versions" {
  description = "Exact chart versions for Flux and NATS on the workload clusters."
  type = object({
    flux = string
    nats = string
  })
  default = {
    flux = "2.20.0"
    nats = "2.15.2"
  }
  nullable = false
}

variable "notification_from_address" {
  description = "Sender address the SMTP requests use. Production requires it to be an SES-verifiable address."
  type        = string
  nullable    = false
}

variable "notification_to_address" {
  description = "Recipient address the SMTP requests use. Production requires it to be an SES-verifiable address."
  type        = string
  nullable    = false
}
