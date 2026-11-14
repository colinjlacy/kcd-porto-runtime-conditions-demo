data "aws_partition" "current" {}

locals {
  node_policies = {
    worker   = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKSWorkerNodePolicy"
    registry = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEC2ContainerRegistryPullOnly"
    cni      = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKS_CNI_Policy"
  }
  node_policy_bindings = {
    for pair in setproduct(keys(var.clusters), keys(local.node_policies)) :
    "${pair[0]}-${pair[1]}" => { cluster = pair[0], policy = pair[1] }
  }
  administrator_bindings = merge([
    for name, cluster in var.clusters : {
      for arn in cluster.administrator_principal_arns :
      "${name}-${sha1(arn)}" => { cluster = name, principal = arn }
    }
  ]...)
}

resource "aws_iam_role" "cluster" {
  for_each = var.clusters
  name     = "${var.name_prefix}-${each.key}-cluster"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow", Action = "sts:AssumeRole"
      Principal = { Service = "eks.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "cluster" {
  for_each   = var.clusters
  role       = aws_iam_role.cluster[each.key].name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKSClusterPolicy"
}

resource "aws_iam_role" "nodes" {
  for_each = var.clusters
  name     = "${var.name_prefix}-${each.key}-nodes"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow", Action = "sts:AssumeRole"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "nodes" {
  for_each   = local.node_policy_bindings
  role       = aws_iam_role.nodes[each.value.cluster].name
  policy_arn = local.node_policies[each.value.policy]
}

resource "aws_eks_cluster" "environment" {
  for_each            = var.clusters
  name                = "${var.name_prefix}-${each.key}"
  role_arn            = aws_iam_role.cluster[each.key].arn
  version             = each.value.kubernetes_version
  deletion_protection = false

  access_config {
    authentication_mode                         = "API"
    bootstrap_cluster_creator_admin_permissions = false
  }
  upgrade_policy {
    support_type = "STANDARD"
  }
  vpc_config {
    subnet_ids              = [for key in sort(tolist(each.value.private_subnet_keys)) : local.private_subnet_ids[key]]
    security_group_ids      = [aws_security_group.control_plane[each.key].id]
    endpoint_private_access = each.value.endpoint_private_access
    endpoint_public_access  = each.value.endpoint_public_access
    public_access_cidrs     = sort(tolist(each.value.public_access_cidrs))
  }

  lifecycle {
    precondition {
      condition     = !each.value.endpoint_private_access || (data.aws_vpc.shared.enable_dns_support && data.aws_vpc.shared.enable_dns_hostnames)
      error_message = "The existing VPC must have DNS support and DNS hostnames enabled for private EKS APIs."
    }
  }

  depends_on = [aws_iam_role_policy_attachment.cluster]
}

resource "aws_launch_template" "nodes" {
  for_each               = var.clusters
  name_prefix            = "${var.name_prefix}-${each.key}-"
  update_default_version = true
  vpc_security_group_ids = [aws_security_group.nodes[each.key].id]

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size           = each.value.node_disk_size_gib
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = true
    }
  }
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }
  tag_specifications {
    resource_type = "instance"
    tags          = { Name = "${var.name_prefix}-${each.key}-node" }
  }
}

resource "aws_eks_node_group" "environment" {
  for_each        = var.clusters
  cluster_name    = aws_eks_cluster.environment[each.key].name
  node_group_name = "demo"
  node_role_arn   = aws_iam_role.nodes[each.key].arn
  subnet_ids      = [for key in sort(tolist(each.value.private_subnet_keys)) : local.private_subnet_ids[key]]
  instance_types  = sort(tolist(each.value.node_instance_types))
  capacity_type   = each.value.node_capacity_type
  ami_type        = each.value.node_architecture == "arm64" ? "AL2023_ARM_64_STANDARD" : "AL2023_x86_64_STANDARD"
  version         = each.value.kubernetes_version
  release_version = each.value.node_ami_release_version

  scaling_config {
    min_size     = each.value.node_min_size
    desired_size = each.value.node_desired_size
    max_size     = each.value.node_max_size
  }
  launch_template {
    id      = aws_launch_template.nodes[each.key].id
    version = tostring(aws_launch_template.nodes[each.key].latest_version)
  }
  labels = { "demo.runtimeconditions.io/environment" = each.key }

  depends_on = [
    aws_iam_role_policy_attachment.nodes,
    aws_route.private_nat,
    aws_route_table_association.private,
    aws_vpc_security_group_ingress_rule.nodes_from_control,
    aws_vpc_security_group_ingress_rule.control_from_nodes,
    aws_vpc_security_group_ingress_rule.nodes_internal,
    aws_vpc_security_group_egress_rule.nodes_outbound,
    aws_vpc_security_group_egress_rule.control_to_nodes,
  ]
}

resource "aws_eks_access_entry" "administrator" {
  for_each      = local.administrator_bindings
  cluster_name  = aws_eks_cluster.environment[each.value.cluster].name
  principal_arn = each.value.principal
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "administrator" {
  for_each      = local.administrator_bindings
  cluster_name  = aws_eks_cluster.environment[each.value.cluster].name
  principal_arn = aws_eks_access_entry.administrator[each.key].principal_arn
  policy_arn    = "arn:${data.aws_partition.current.partition}:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
  access_scope {
    type = "cluster"
  }
}

output "clusters" {
  description = "Connection metadata for the separate local Kubernetes/Helm bootstrap root."
  value = {
    for name, cluster in aws_eks_cluster.environment : name => {
      name                   = cluster.name
      arn                    = cluster.arn
      endpoint               = cluster.endpoint
      certificate_authority  = cluster.certificate_authority[0].data
      node_security_group_id = aws_security_group.nodes[name].id
      oidc_issuer            = cluster.identity[0].oidc[0].issuer
    }
  }
  depends_on = [aws_eks_node_group.environment, aws_eks_access_policy_association.administrator]
}
