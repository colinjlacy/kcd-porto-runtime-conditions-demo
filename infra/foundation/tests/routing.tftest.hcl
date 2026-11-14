# Local plan-only regression checks. Every AWS call is mocked.
# The zero account number and resource IDs below are synthetic fixtures.
mock_provider "aws" {
  mock_data "aws_partition" {
    defaults = { partition = "aws" }
  }
  mock_data "aws_vpc" {
    defaults = {
      cidr_block           = "10.42.0.0/16"
      main_route_table_id  = "rtb-11111111"
      enable_dns_support   = true
      enable_dns_hostnames = true
      cidr_block_associations = [{
        association_id = "vpc-cidr-assoc-11111111"
        cidr_block     = "10.42.0.0/16"
        state          = "associated"
      }]
    }
  }
  mock_data "aws_subnets" {
    defaults = { ids = ["subnet-11111111"] }
  }
  mock_data "aws_subnet" {
    defaults = { vpc_id = "vpc-11111111", cidr_block = "10.42.0.0/20", tags = {} }
  }
  mock_data "aws_internet_gateway" {
    defaults = { id = "igw-11111111" }
  }
  mock_data "aws_route_tables" {
    defaults = { ids = [] }
  }
  mock_data "aws_route_table" {
    defaults = {
      routes = [{
        cidr_block                 = "0.0.0.0/0"
        gateway_id                 = "igw-11111111"
        carrier_gateway_id         = ""
        core_network_arn           = ""
        destination_prefix_list_id = ""
        egress_only_gateway_id     = ""
        instance_id                = ""
        ipv6_cidr_block            = ""
        local_gateway_id           = ""
        nat_gateway_id             = ""
        network_interface_id       = ""
        odb_network_arn            = ""
        transit_gateway_id         = ""
        vpc_endpoint_id            = ""
        vpc_peering_connection_id  = ""
      }]
    }
  }
  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::000000000000:role/test-only" }
  }
  mock_resource "aws_eks_cluster" {
    defaults = {
      arn                   = "arn:aws:eks:eu-west-3:000000000000:cluster/test-only"
      certificate_authority = [{ data = "dGVzdA==" }]
      identity              = [{ oidc = [{ issuer = "https://issuer.example.test" }] }]
    }
  }
  mock_resource "aws_launch_template" {
    defaults = { id = "lt-11111111111111111", latest_version = 1 }
  }
  mock_resource "aws_security_group" {
    defaults = { id = "sg-11111111" }
  }
  mock_resource "aws_subnet" {
    defaults = { id = "subnet-22222222" }
  }
  mock_resource "aws_eip" {
    defaults = { id = "eipalloc-11111111", public_ip = "203.0.113.1" }
  }
  mock_resource "aws_nat_gateway" {
    defaults = { id = "nat-11111111" }
  }
  mock_resource "aws_route_table" {
    defaults = { id = "rtb-33333333" }
  }
}

variables {
  aws_account_id = "000000000000"
  aws_region     = "eu-west-3"
  name_prefix    = "routing-test"

  network = {
    vpc_id = "vpc-11111111"
    public_subnet_ids = {
      a      = "subnet-11111111"
      unused = "subnet-44444444"
    }
    nat_gateways = { shared = { public_subnet = "a" } }
    private_subnets = {
      first  = { cidr = "10.42.16.0/20", availability_zone = "eu-west-3a", nat_gateway = "shared" }
      second = { cidr = "10.42.32.0/20", availability_zone = "eu-west-3b", nat_gateway = "shared" }
    }
  }

  clusters = {
    for name, instance in { management = "t3.large", dev = "t3.medium", production = "t3.medium" } : name => {
      kubernetes_version               = "1.35"
      node_architecture                = "amd64"
      node_capacity_type               = "ON_DEMAND"
      node_ami_release_version         = "1.35.9-20261107"
      node_instance_types              = [instance]
      private_subnet_keys              = ["first", "second"]
      node_min_size                    = 1
      node_desired_size                = 1
      node_max_size                    = 1
      node_disk_size_gib               = 20
      endpoint_private_access          = true
      endpoint_public_access           = false
      public_access_cidrs              = []
      administrator_principal_arns     = ["arn:aws:iam::000000000000:role/test-only"]
    }
  }
}

run "inherited_main_route_table" {
  command = plan

  assert {
    condition     = data.aws_route_table.public["a"].route_table_id == "rtb-11111111"
    error_message = "A subnet without an explicit association must use its VPC's main route table."
  }
  assert {
    condition     = length(data.aws_route_table.public) == 1 && length(data.aws_route_tables.public_association) == 1
    error_message = "Only public subnets selected for new NAT gateways need route-table lookups."
  }
}

run "explicit_subnet_route_table" {
  command = plan

  override_data {
    target = data.aws_route_tables.public_association
    values = { ids = ["rtb-22222222"] }
  }
  assert {
    condition     = data.aws_route_table.public["a"].route_table_id == "rtb-22222222"
    error_message = "An explicit subnet association must take precedence over the VPC's main route table."
  }
}
