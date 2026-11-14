# Shipment notification deployment demo

Build one TypeScript application image that consumes shipment events from NATS JetStream, records them in PostgreSQL, and sends email through SMTP. A generated Runtime Conditions Profile triggers independent provisioning and deployment in dev and production.

## Confirmed requirements

| Area | Decision |
| --- | --- |
| Location | New standalone repository; this folder is its starting point |
| Application | TypeScript, no-op extension declarations, Dockerfile |
| Configuration | One image and common code; environment variables supply configuration |
| CI | GitHub Actions; install both RC tools through APT in Linux |
| Outputs | OCI image in GHCR and RCProfile as a GitHub Actions artifact |
| Kubernetes | Management, dev, and production are separate EKS clusters in one AWS account |
| Platform | Kratix with a watcher adapter; the RCProfile CRD remains unchanged |
| Network | Caller-selected shared VPC and subnet layout; cluster security rules remain separate |
| Region and account | Required deployment inputs; no personal defaults |
| Production capacity | Small demo resources; production behavior comes from integration choices |
| Trigger | Successful creation or update of an RCProfile instance on management |
| Deployment rule | Each environment waits for its own fully provisioned dependencies |
| Dev integrations | PostgreSQL container, MailHog, separate dev NATS deployment |
| Production integrations | Aurora Serverless PostgreSQL, SES SMTP in a supported region, separate production NATS deployment |
| Events | Dev and production events are isolated |
| Extensions | Approved SMTP/configuration additions; reuse the existing NATS service extension |

## Current state

This folder contains planning documents and an OpenTofu foundation for three EKS clusters. It is not yet initialized as a Git repository and has no GitHub remote. No AWS resources have been created.

- [Implementation plan](IMPLEMENTATION-PLAN.md): decisions, ordered work, and acceptance evidence.
- [Extension proposal](EXTENSION-PROPOSAL.md): approved vocabulary changes and release references.
- `infra/foundation/`: pinned OpenTofu/AWS provider, EKS clusters and node groups, IAM access, security rules, and optional private networking. State backend and Kubernetes/Helm bootstrap remain to be implemented.

The approved extension source changes are implemented in the sibling `extensions` repository. Synchronizing the 23 generated TypeScript files was deferred by the user to a separate step; the checked-in binding packages remain unchanged. Temporary regenerated packages compiled and produced the required profile, but publication and clean Linux APT acceptance remain pending.

Local verification on 2026-11-14 found `rc` v0.3.0 and TypeScript profiler 0.2.1 ready. The public amd64 APT index lists `rc-cli=0.3.0-1` and `rc-profiler-typescript=0.2.1-1`. Installation and generation in a clean Linux container are required acceptance checks.

## Foundation input contract

Supply `aws_account_id`, `aws_region`, `name_prefix`, `network`, and `clusters`. Credentials use the standard AWS credential chain; the module does not select a named AWS profile. The account input guards against deploying into the wrong account.

`network.vpc_id` selects any suitable VPC. A separate OpenTofu root or an existing infrastructure system can provision that VPC first. The foundation reads it as data and never owns or destroys it.

| Input | Ownership and behavior |
| --- | --- |
| `existing_private_subnets` | Map of `{ id, availability_zone }`; subnet routes remain caller-owned |
| `private_subnets` | Map of new `{ cidr, availability_zone, nat_gateway? }`; the foundation owns these subnets and route tables |
| `existing_nat_gateway_ids` | Map of caller-owned NAT gateway IDs, available to new private subnet routes |
| `nat_gateways` | Optional map of new public NAT gateways, each selecting a key in `public_subnet_ids` |
| `public_subnet_ids` | Caller-owned public subnet IDs, required only for new public NAT gateways |

Existing and new resources can be combined; their map keys must be distinct. Each cluster selects private subnet keys spanning at least two availability zones. There is no fixed NAT gateway count. Omitting a new subnet's `nat_gateway` creates no default route; provide the connectivity needed by EKS nodes and workloads through your network design.

For example, an existing network needs no public subnet or NAT inputs:

```hcl
network = {
  vpc_id = "<your-vpc-id>"
  existing_private_subnets = {
    first  = { id = "<first-private-subnet-id>", availability_zone = "<first-zone>" }
    second = { id = "<second-private-subnet-id>", availability_zone = "<second-zone>" }
  }
}
```

Only when creating a public NAT gateway for internet egress does the module check its public subnet's route to that VPC's internet gateway. Configure that public network in its owning infrastructure stage. Existing-network configurations do not require an internet gateway lookup. See [AWS NAT gateway connectivity](https://docs.aws.amazon.com/vpc/latest/userguide/vpc-nat-gateway.html).

Cluster API endpoint settings, administrator identities, instance sizes, and version pins are explicit inputs. `bootstrap_source_cidrs` defaults to empty; provide it when your private API access needs those ingress rules. Endpoint reachability must exist from the machine running Kubernetes/Helm OpenTofu. A VPC ID alone does not provide that connection.

## Installation sequence

1. Provision or select the network and configure state storage.
2. Apply the AWS foundation with your own inputs and credentials.
3. From a machine that can reach the chosen APIs, run the separate local Kubernetes/Helm bootstrap root after EKS is ready. This root remains planned work; no CodeBuild job or bootstrap Lambda is needed.

Paris, one NAT gateway, one `t3.large` management node, and one `t3.medium` node per workload cluster are the initial demonstration's choices. Other operators supply their own values. The initial Aurora writer range is 0.5-2 ACUs with no reader.

## Remaining decisions

1. Choose how the Kratix pipelines execute OpenTofu and deliver manifests to workload clusters.
2. Choose state storage, version pins, and deployment-specific subnet/endpoint inputs.
3. Choose the SES SMTP region and provide the sender identity, recipient, and identity verification arrangements.
4. Choose GitHub ownership, repository name, visibility, and build trigger.
5. Resolve secrets, event/retry behavior, and teardown retention in the implementation plan.

The next implementation batch will name at most five files before editing them. Each file may receive at most 250 lines of edits per turn, following the workspace instructions.

## Regional references

- [EKS endpoints](https://docs.aws.amazon.com/general/latest/gr/eks.html)
- [RDS regions](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/Concepts.RegionsAndAvailabilityZones.html)
- [SES endpoints](https://docs.aws.amazon.com/general/latest/gr/ses.html): Spain has an API endpoint; its SMTP endpoints table does not list Spain.
- [Runtime Conditions APT instructions](https://github.com/runtimeconditions/packages)
