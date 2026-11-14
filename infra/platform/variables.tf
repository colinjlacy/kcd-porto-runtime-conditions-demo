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
    cert_manager = string
    kratix       = string
  })
  default = {
    cert_manager = "v1.21.3"
    kratix       = "v0.0.1"
  }
  nullable = false

  validation {
    condition = alltrue([
      for version in values(var.chart_versions) :
      can(regex("^v?[0-9]+\\.[0-9]+\\.[0-9]+(-[0-9A-Za-z.-]+)?(\\+[0-9A-Za-z.-]+)?$", version))
    ])
    error_message = "Pin exact cert-manager and Kratix chart versions; ranges and latest are not accepted."
  }
}

variable "rcprofile_crd_file" {
  description = "Path to the unchanged runtimeconditions.io RuntimeConditionsProfile CRD YAML from a pinned checkout."
  type        = string
  nullable    = false

  validation {
    condition = try(
      fileexists(var.rcprofile_crd_file) &&
      yamldecode(file(var.rcprofile_crd_file)).apiVersion == "apiextensions.k8s.io/v1" &&
      yamldecode(file(var.rcprofile_crd_file)).kind == "CustomResourceDefinition" &&
      yamldecode(file(var.rcprofile_crd_file)).metadata.name == "runtimeconditionsprofiles.runtimeconditions.io", false
    )
    error_message = "Supply an existing YAML file containing the RuntimeConditionsProfile CRD."
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
