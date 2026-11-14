data "aws_vpc" "shared" {
  id = var.network.vpc_id
}

data "aws_internet_gateway" "shared" {
  count = length(var.network.nat_gateways) > 0 ? 1 : 0
  filter {
    name   = "attachment.vpc-id"
    values = [data.aws_vpc.shared.id]
  }
}

data "aws_subnet" "public" {
  for_each = local.nat_public_subnet_ids
  id       = each.value
}

data "aws_route_tables" "public_association" {
  for_each = local.nat_public_subnet_ids
  vpc_id   = var.network.vpc_id

  filter {
    name   = "association.subnet-id"
    values = [each.value]
  }
}

data "aws_route_table" "public" {
  for_each = local.nat_public_subnet_ids
  route_table_id = coalesce(
    one(data.aws_route_tables.public_association[each.key].ids),
    data.aws_vpc.shared.main_route_table_id
  )
}

data "aws_subnets" "existing" {
  count = length(var.network.private_subnets) > 0 ? 1 : 0
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.shared.id]
  }
}

data "aws_subnet" "existing" {
  for_each = toset(try(data.aws_subnets.existing[0].ids, []))
  id       = each.value
}

data "aws_subnet" "existing_private" {
  for_each          = var.network.existing_private_subnets
  id                = each.value.id
  availability_zone = each.value.availability_zone

  lifecycle {
    postcondition {
      condition     = self.vpc_id == var.network.vpc_id
      error_message = "Existing private subnets must belong to the supplied VPC."
    }
  }
}

locals {
  nat_public_subnet_ids = {
    for key, id in var.network.public_subnet_ids : key => id
    if contains([for gateway in values(var.network.nat_gateways) : gateway.public_subnet], key)
  }
  private_subnet_ids = merge(
    { for key, subnet in aws_subnet.private : key => subnet.id },
    { for key, subnet in data.aws_subnet.existing_private : key => subnet.id }
  )
  private_subnet_zones = merge(
    { for key, subnet in var.network.private_subnets : key => subnet.availability_zone },
    { for key, subnet in var.network.existing_private_subnets : key => subnet.availability_zone }
  )
  nat_gateway_ids = merge(
    var.network.existing_nat_gateway_ids,
    { for key, gateway in aws_nat_gateway.egress : key => gateway.id }
  )
}

resource "aws_subnet" "private" {
  for_each = var.network.private_subnets

  vpc_id                  = data.aws_vpc.shared.id
  cidr_block              = each.value.cidr
  availability_zone       = each.value.availability_zone
  map_public_ip_on_launch = false

  tags = {
    Name                              = "${var.name_prefix}-private-${each.key}"
    "kubernetes.io/role/internal-elb" = "1"
  }

  lifecycle {
    precondition {
      condition = anytrue([
        for association in data.aws_vpc.shared.cidr_block_associations :
        cidrcontains(association.cidr_block, each.value.cidr)
      ])
      error_message = "A requested private subnet is outside the supplied VPC's IPv4 CIDR blocks."
    }
    precondition {
      condition = alltrue([
        for subnet in values(data.aws_subnet.existing) :
        (try(subnet.tags.Project, "") == var.name_prefix && try(subnet.tags.ManagedBy, "") == "OpenTofu" &&
        try(subnet.tags.Name, "") == "${var.name_prefix}-private-${each.key}" && subnet.cidr_block == each.value.cidr) ||
        (!cidrcontains(subnet.cidr_block, cidrhost(each.value.cidr, 0)) && !cidrcontains(each.value.cidr, cidrhost(subnet.cidr_block, 0)))
      ])
      error_message = "A requested private subnet overlaps an existing subnet outside this demo."
    }
  }
}

resource "aws_eip" "nat" {
  for_each = var.network.nat_gateways

  domain = "vpc"
  tags   = { Name = "${var.name_prefix}-nat-${each.key}" }
}

resource "aws_nat_gateway" "egress" {
  for_each = var.network.nat_gateways

  availability_mode = "zonal"
  connectivity_type = "public"
  allocation_id     = aws_eip.nat[each.key].id
  subnet_id         = data.aws_subnet.public[each.value.public_subnet].id
  tags              = { Name = "${var.name_prefix}-nat-${each.key}" }

  lifecycle {
    precondition {
      condition     = data.aws_subnet.public[each.value.public_subnet].vpc_id == data.aws_vpc.shared.id
      error_message = "The public subnet for a new NAT gateway must belong to the supplied VPC."
    }
    precondition {
      condition = anytrue([
        for route in data.aws_route_table.public[each.value.public_subnet].routes :
        route.cidr_block == "0.0.0.0/0" && route.gateway_id == data.aws_internet_gateway.shared[0].id
      ])
      error_message = "A new public NAT gateway needs its supplied public subnet to route 0.0.0.0/0 through the supplied VPC's internet gateway. Configure that caller-owned public route before this stage."
    }
  }
}

resource "aws_route_table" "private" {
  for_each = var.network.private_subnets

  vpc_id = data.aws_vpc.shared.id
  tags   = { Name = "${var.name_prefix}-private-${each.key}" }
}

resource "aws_route" "private_nat" {
  for_each = { for key, subnet in var.network.private_subnets : key => subnet if subnet.nat_gateway != null }

  route_table_id         = aws_route_table.private[each.key].id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = local.nat_gateway_ids[each.value.nat_gateway]
}

resource "aws_route_table_association" "private" {
  for_each = aws_subnet.private

  subnet_id      = each.value.id
  route_table_id = aws_route_table.private[each.key].id
}

output "network" {
  description = "Shared VPC, private subnet IDs/zones, and NAT public IPs for later bootstrap stages."
  value = {
    vpc_id               = data.aws_vpc.shared.id
    private_subnet_ids   = local.private_subnet_ids
    private_subnet_zones = local.private_subnet_zones
    nat_public_ips       = { for key, address in aws_eip.nat : key => address.public_ip }
  }

  depends_on = [aws_route.private_nat, aws_route_table_association.private]
}
