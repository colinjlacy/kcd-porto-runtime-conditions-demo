locals {
  bootstrap_ingress = {
    for pair in setproduct(keys(var.clusters), var.bootstrap_source_cidrs) :
    "${pair[0]}-${sha1(pair[1])}" => { cluster = pair[0], cidr = pair[1] }
  }
}

resource "aws_security_group" "control_plane" {
  for_each    = var.clusters
  name_prefix = "${var.name_prefix}-${each.key}-api-"
  description = "Private API access for ${each.key}"
  vpc_id      = data.aws_vpc.shared.id
}

resource "aws_security_group" "nodes" {
  for_each    = var.clusters
  name_prefix = "${var.name_prefix}-${each.key}-nodes-"
  description = "Nodes and pods belonging to ${each.key}"
  vpc_id      = data.aws_vpc.shared.id
}

resource "aws_vpc_security_group_ingress_rule" "nodes_internal" {
  for_each                     = var.clusters
  security_group_id            = aws_security_group.nodes[each.key].id
  referenced_security_group_id = aws_security_group.nodes[each.key].id
  ip_protocol                  = "-1"
  description                  = "Intra-cluster node and pod traffic"
}

resource "aws_vpc_security_group_ingress_rule" "control_from_nodes" {
  for_each                     = var.clusters
  security_group_id            = aws_security_group.control_plane[each.key].id
  referenced_security_group_id = aws_security_group.nodes[each.key].id
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
  description                  = "Nodes reach their own Kubernetes API"
}

resource "aws_vpc_security_group_ingress_rule" "nodes_from_control" {
  for_each                     = var.clusters
  security_group_id            = aws_security_group.nodes[each.key].id
  referenced_security_group_id = aws_security_group.control_plane[each.key].id
  ip_protocol                  = "-1"
  description                  = "Control-plane access to kubelets and webhooks"
}

resource "aws_vpc_security_group_egress_rule" "control_to_nodes" {
  for_each                     = var.clusters
  security_group_id            = aws_security_group.control_plane[each.key].id
  referenced_security_group_id = aws_security_group.nodes[each.key].id
  ip_protocol                  = "-1"
}

resource "aws_vpc_security_group_egress_rule" "nodes_outbound" {
  for_each          = var.clusters
  security_group_id = aws_security_group.nodes[each.key].id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
  description       = "Private-node outbound traffic; internet routes use NAT"
}

resource "aws_vpc_security_group_ingress_rule" "local_bootstrap" {
  for_each          = local.bootstrap_ingress
  security_group_id = aws_security_group.control_plane[each.value.cluster].id
  cidr_ipv4         = each.value.cidr
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  description       = "Local OpenTofu bootstrap over an existing private route"
}

resource "aws_security_group" "profile_publisher" {
  name_prefix = "${var.name_prefix}-publisher-"
  description = "Previously selected RCProfile publisher Lambda"
  vpc_id      = data.aws_vpc.shared.id
}

resource "aws_vpc_security_group_egress_rule" "publisher_https" {
  security_group_id = aws_security_group.profile_publisher.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}

# The production database created by the postgres-prod Promise uses this group.
resource "aws_vpc_security_group_ingress_rule" "postgres_from_production_nodes" {
  security_group_id            = aws_security_group.profile_publisher.id
  referenced_security_group_id = aws_security_group.nodes["production"].id
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
  description                  = "Production workloads reach Aurora PostgreSQL"
}

resource "aws_vpc_security_group_ingress_rule" "management_from_publisher" {
  security_group_id            = aws_security_group.control_plane["management"].id
  referenced_security_group_id = aws_security_group.profile_publisher.id
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
}
