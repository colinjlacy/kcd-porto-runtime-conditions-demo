variable "aws_account_id" {
  description = "AWS account allowed to own all three EKS clusters."
  type        = string
  nullable    = false

  validation {
    condition     = can(regex("^[0-9]{12}$", var.aws_account_id))
    error_message = "aws_account_id must contain exactly 12 digits."
  }
}

variable "aws_region" {
  description = "AWS region containing the caller-selected VPC and EKS clusters."
  type        = string
  nullable    = false

  validation {
    condition     = can(regex("^[a-z]{2}(-[a-z]+)+-[0-9]+$", var.aws_region))
    error_message = "Supply an AWS region name."
  }
}

variable "name_prefix" {
  description = "Lowercase resource prefix; environment names will distinguish clusters."
  type        = string
  nullable    = false

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,39}$", var.name_prefix))
    error_message = "Use 1 to 40 lowercase letters, digits, or hyphens, starting with a letter."
  }
}

variable "bootstrap_source_cidrs" {
  description = "Optional source IPv4 CIDRs allowed to reach private Kubernetes APIs; routing is caller-owned."
  type        = set(string)
  default     = []
  nullable    = false

  validation {
    condition = alltrue([
      for cidr in var.bootstrap_source_cidrs : try(cidrnetmask(cidr) != "" && tonumber(split("/", cidr)[1]) > 0, false)
    ])
    error_message = "Bootstrap source CIDRs must be IPv4; 0.0.0.0/0 is not accepted."
  }
}

variable "network" {
  description = "Caller-owned VPC, optional existing private subnets/NATs, and optional new private subnets/public NATs."
  type = object({
    vpc_id            = string
    public_subnet_ids = optional(map(string), {})
    nat_gateways = optional(map(object({
      public_subnet = string
    })), {})
    existing_nat_gateway_ids = optional(map(string), {})
    private_subnets = optional(map(object({
      cidr              = string
      availability_zone = string
      nat_gateway       = optional(string)
    })), {})
    existing_private_subnets = optional(map(object({
      id                = string
      availability_zone = string
    })), {})
  })
  nullable = false

  validation {
    condition = (
      length(trimspace(var.network.vpc_id)) > 0 &&
      length(setintersection(toset(keys(var.network.private_subnets)), toset(keys(var.network.existing_private_subnets)))) == 0 &&
      length(setintersection(toset(keys(var.network.nat_gateways)), toset(keys(var.network.existing_nat_gateway_ids)))) == 0
    )
    error_message = "Supply a VPC ID and use distinct keys for existing and new resources."
  }

  validation {
    condition = alltrue([
      for subnet in concat(values(var.network.private_subnets), values(var.network.existing_private_subnets)) :
      startswith(subnet.availability_zone, var.aws_region)
    ])
    error_message = "Every private subnet must use an availability zone in aws_region."
  }

  validation {
    condition = alltrue([
      for gateway in values(var.network.nat_gateways) : contains(keys(var.network.public_subnet_ids), gateway.public_subnet)
      ]) && alltrue([
      for subnet in values(var.network.private_subnets) : subnet.nat_gateway == null ? true :
      contains(concat(keys(var.network.nat_gateways), keys(var.network.existing_nat_gateway_ids)), subnet.nat_gateway)
    ])
    error_message = "New NATs must reference a supplied public subnet; optional private-subnet NAT references must name an existing or new NAT."
  }

  validation {
    condition = alltrue([
      for subnet in values(var.network.private_subnets) : try(
        cidrnetmask(subnet.cidr) != "" &&
        tonumber(split("/", subnet.cidr)[1]) >= 16 && tonumber(split("/", subnet.cidr)[1]) <= 28, false
      )
    ])
    error_message = "Each new subnet must be an IPv4 /16 through /28 CIDR."
  }

  validation {
    condition = alltrue(flatten([
      for i, a in values(var.network.private_subnets) : [
        for j, b in values(var.network.private_subnets) : try(
          i == j || (!cidrcontains(a.cidr, cidrhost(b.cidr, 0)) && !cidrcontains(b.cidr, cidrhost(a.cidr, 0))), false
        )
      ]
    ]))
    error_message = "New private subnet CIDRs must not overlap."
  }
}

variable "clusters" {
  description = "Explicit sizing, API access, and administrator roles for each separate EKS cluster."
  type = map(object({
    kubernetes_version           = string
    node_architecture            = string
    node_capacity_type           = string
    node_ami_release_version     = string
    node_instance_types          = set(string)
    private_subnet_keys          = set(string)
    node_min_size                = number
    node_desired_size            = number
    node_max_size                = number
    node_disk_size_gib           = number
    endpoint_private_access      = bool
    endpoint_public_access       = bool
    public_access_cidrs          = set(string)
    administrator_principal_arns = set(string)
  }))
  nullable = false

  validation {
    condition     = toset(keys(var.clusters)) == toset(["management", "dev", "production"])
    error_message = "clusters must contain exactly management, dev, and production."
  }

  validation {
    condition = alltrue([
      for cluster in values(var.clusters) :
      can(regex("^1\\.[0-9]+$", cluster.kubernetes_version)) &&
      contains(["amd64", "arm64"], cluster.node_architecture) &&
      contains(["ON_DEMAND", "SPOT"], cluster.node_capacity_type) &&
      length(trimspace(cluster.node_ami_release_version)) > 0 &&
      length(cluster.node_instance_types) > 0 && alltrue([
        for instance_type in cluster.node_instance_types : length(trimspace(instance_type)) > 0
      ])
    ])
    error_message = "Supply a Kubernetes 1.x version, node architecture, capacity type, pinned AMI release, and instance types."
  }

  validation {
    condition = alltrue([
      for cluster in values(var.clusters) :
      cluster.node_min_size >= 0 &&
      cluster.node_min_size <= cluster.node_desired_size &&
      cluster.node_desired_size <= cluster.node_max_size &&
      cluster.node_max_size >= 1 &&
      cluster.node_disk_size_gib >= 1 &&
      alltrue([
        for size in [cluster.node_min_size, cluster.node_desired_size, cluster.node_max_size, cluster.node_disk_size_gib] :
        size == floor(size)
      ])
    ])
    error_message = "Use whole-number node/disk sizes with 0 <= min <= desired <= max, max >= 1, and disk >= 1 GiB."
  }

  validation {
    condition = alltrue([
      for cluster in values(var.clusters) :
      (cluster.endpoint_private_access || cluster.endpoint_public_access) &&
      (cluster.endpoint_public_access ? length(cluster.public_access_cidrs) > 0 : length(cluster.public_access_cidrs) == 0) &&
      alltrue([for cidr in cluster.public_access_cidrs : can(cidrnetmask(cidr))])
    ])
    error_message = "Enable an API endpoint; explicitly supply IPv4 CIDRs only when public API access is enabled."
  }

  validation {
    condition = alltrue([
      for cluster in values(var.clusters) :
      length(cluster.administrator_principal_arns) > 0 && alltrue([
        for arn in cluster.administrator_principal_arns :
        can(regex("^arn:${data.aws_partition.current.partition}:iam::${var.aws_account_id}:(role|user)/.+$", arn))
      ])
    ])
    error_message = "Supply at least one administrator IAM user or role in aws_account_id for each cluster."
  }

  validation {
    condition = alltrue([
      for cluster in values(var.clusters) :
      alltrue([for key in cluster.private_subnet_keys : contains(keys(local.private_subnet_zones), key)]) &&
      length(toset([for key in cluster.private_subnet_keys : try(local.private_subnet_zones[key], "")])) >= 2
    ])
    error_message = "Each cluster must select supplied existing or new private-subnet keys in at least two availability zones."
  }
}
