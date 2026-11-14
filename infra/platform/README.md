# Platform bootstrap

Run this separate OpenTofu root after the AWS foundation apply finishes. It discovers existing EKS clusters through `aws_eks_cluster` data sources and manages resources inside those clusters. Foundation retains ownership of EKS clusters, networking, and administrator access entries.

## Current resources

| Cluster | Resources installed by this batch |
| --- | --- |
| Management | Unmodified RCProfile CRD, profile namespace, cert-manager, Kratix controllers |
| Dev | Application support namespace |
| Production | Application support namespace |

Each cluster has its own Kubernetes and Helm provider aliases. The caller supplies cluster names; there are no account, region, endpoint, or AWS profile defaults. Connections use the discovered endpoint/CA and AWS CLI `eks get-token`, which can refresh credentials during long operations. Kubeconfig changes are unnecessary. See the [Kubernetes provider guidance](https://registry.terraform.io/providers/hashicorp/kubernetes/3.5.0/docs).

## Prerequisites

- OpenTofu 1.12.6, AWS CLI v2, and AWS credentials for the intended account.
- All three clusters are ACTIVE and foundation's node groups/access entries are ready.
- The execution machine can resolve and reach each Kubernetes API, and its IAM principal has suitable access entries. Private endpoints require an existing private route and allowed source traffic. AWS metadata lookups and NAT egress do not establish that route.
- The original RCProfile CRD YAML is available from a pinned checkout. Its path is an input; its schema is never rewritten for Kratix.
- Separate platform state. The default is a separate local state file; configure a backend before sharing execution. Keep state, provider directories, and local variable values outside commits.

## Inputs and execution

Set `aws_account_id`, `aws_region`, `cluster_names`, and `rcprofile_crd_file`. Chart pins default to the approved cert-manager `v1.21.3` and Kratix chart `v0.0.1` (Kratix `1.16.0`); override `chart_versions` to use other exact releases. Namespace names, API proxy URL, and Helm timeout are configurable.

For this workspace layout, from `infra/platform`, the following commands derive initial connection inputs from the completed foundation outputs. Other operators can provide these inputs directly; the OpenTofu code does not depend on foundation's state location.

```sh
export TF_VAR_cluster_names="$(tofu -chdir=../foundation output -json clusters | jq -c 'map_values(.name)')"
export TF_VAR_aws_account_id="$(tofu -chdir=../foundation output -json clusters | jq -r '.management.arn | split(":")[4]')"
export TF_VAR_aws_region="$(tofu -chdir=../foundation output -json clusters | jq -r '.management.arn | split(":")[3]')"
export TF_VAR_rcprofile_crd_file="$(realpath ../../../runtime-conditions-crd/config/crd/bases/runtimeconditions.io_runtimeconditionsprofiles.yaml)"

tofu init
tofu validate
tofu plan -out=platform.plan
tofu apply platform.plan
tofu plan -detailed-exitcode
```

Use your selected AWS credentials for every command, including AWS CLI token execution. A second unchanged plan should exit 0; exit 2 means changes remain. Commit the generated provider lockfile after initialization. No Kubernetes resources were installed while creating this scaffold.

The CRD install waits for its Established condition. The cert-manager release installs its CRDs and waits for readiness before Kratix starts. [cert-manager Helm guidance](https://cert-manager.io/docs/installation/helm/), [Kratix chart prerequisites](https://github.com/syntasso/helm-charts)

## Subsequent batches

1. Install the approved EBS CSI and EKS Pod Identity add-ons, their scoped IAM permissions, and gp3 storage classes for the workload clusters. Pin add-on versions compatible with each cluster.
2. Install separate persistent NATS deployments after agreeing broker count, volume sizes, authentication, TLS, and credential ownership.
3. Select the Kratix state store and means of applying generated manifests to dev and production. Register their Destinations after the Kratix CRDs exist.
4. Implement the watcher adapter and environment Promise/workflows for NATS, SMTP, and PostgreSQL in a later root. Applying RCProfiles has no provisioning effect until that adapter and Promise are installed.

Retain the existing AWS VPC CNI and kube-proxy. The demo's application conditions cover NATS, SMTP, and PostgreSQL.

Kratix's sample SeaweedFS state store, credentials, and example Destinations are disabled. This initial root installs controllers without choosing a delivery backend. Custom resources using newly installed CRDs belong in a later plan/apply so Kubernetes schema discovery can succeed.

Before cluster teardown, remove workflow-owned application resources and support services, then destroy platform resources while the Kubernetes APIs remain reachable. Destroy the foundation last.
