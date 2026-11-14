# Platform bootstrap

Run this separate OpenTofu root after the AWS foundation apply finishes. It discovers existing EKS clusters through `aws_eks_cluster` data sources and manages resources inside those clusters. Foundation retains ownership of EKS clusters, networking, and administrator access entries.

## Current resources

| Cluster | Resources installed by this batch |
| --- | --- |
| Management | RCProfile CRD Helm chart `0.1.1`, profile namespace, cert-manager, Kratix controllers |
| Dev | Application support namespace |
| Production | Application support namespace |

Each cluster has its own Kubernetes and Helm provider aliases. The caller supplies cluster names; there are no account, region, endpoint, or AWS profile defaults. Connections use the discovered endpoint/CA and AWS CLI `eks get-token`, which can refresh credentials during long operations. Kubeconfig changes are unnecessary. See the [Kubernetes provider guidance](https://registry.terraform.io/providers/hashicorp/kubernetes/3.5.0/docs).

## Profile ownership and triggering

This root installs the RCProfile **CustomResourceDefinition**, which defines the Kubernetes API, using the published `oci://ghcr.io/runtimeconditions/charts/runtime-conditions-crd` Helm chart. OpenTofu does not generate or apply RCProfile **instances**. Profile publishers submit those resources separately after platform installation.

The later watcher must observe all RCProfiles across management-cluster namespaces and dispatch separate Kratix dev/production requests for each source profile. Reconciliation identity includes namespace, name, and UID; requests, state, workload-owned resources, and status remain separate per profile/environment. No selector may restrict processing to the shipment demo's profile name or labels. Existing profiles must reconcile after a watcher restart, and failure of one profile must not block others.

The demo's submission namespace and shipment integration names are examples. Promises fulfill each profile's declared conditions. The bootstrap namespace does not constrain the watcher's namespace scope.

## Prerequisites

- OpenTofu 1.12.6, AWS CLI v2, and AWS credentials for the intended account.
- All three clusters are ACTIVE and foundation's node groups/access entries are ready.
- The execution machine can resolve and reach each Kubernetes API, and its IAM principal has suitable access entries. Private endpoints require an existing private route and allowed source traffic. AWS metadata lookups and NAT egress do not establish that route.
- Network access to the public GHCR chart package. A local CRD checkout is unnecessary; the published chart supplies the schema without rewriting it for Kratix.
- Separate platform state. The default is a separate local state file; configure a backend before sharing execution. Keep state, provider directories, and local variable values outside commits.

## Inputs and execution

Set `aws_account_id`, `aws_region`, and `cluster_names`. Chart pins default to cert-manager `v1.21.3`, Kratix chart `v0.0.1` (Kratix `1.16.0`), and RCProfile CRD chart `0.1.1`; override `chart_versions` to use other exact releases. Existing chart-version objects that omit `rcprofile_crd` receive `0.1.1`. Namespace names, API proxy URL, and Helm timeout are configurable.

The ignored `default.tfvars` contains local values, including the chart pins. Pass `-var-file=default.tfvars` to plan/apply when using it; OpenTofu does not load that filename automatically. Remove the obsolete `rcprofile_crd_file` assignment from any other variable files.

For this workspace layout, from `infra/platform`, the following commands derive initial connection inputs from the completed foundation outputs. Other operators can provide these inputs directly; the OpenTofu code does not depend on foundation's state location.

```sh
export TF_VAR_cluster_names="$(tofu -chdir=../foundation output -json clusters | jq -c 'map_values(.name)')"
export TF_VAR_aws_account_id="$(tofu -chdir=../foundation output -json clusters | jq -r '.management.arn | split(":")[4]')"
export TF_VAR_aws_region="$(tofu -chdir=../foundation output -json clusters | jq -r '.management.arn | split(":")[3]')"

tofu init
tofu validate
tofu plan -out=platform.plan
tofu apply platform.plan
tofu plan -detailed-exitcode
```

Use your selected AWS credentials for every command, including AWS CLI token execution. A second unchanged plan should exit 0; exit 2 means changes remain. Commit the generated provider lockfile after initialization. No Kubernetes resources were installed while creating this scaffold.

The profile namespace is created before the RCProfile Helm release, and the publisher's Kubernetes Role waits for that release. Helm installs CRDs before the chart's RBAC resources. The cert-manager release installs its CRDs and waits for readiness before Kratix starts. [cert-manager Helm guidance](https://cert-manager.io/docs/installation/helm/), [Kratix chart prerequisites](https://github.com/syntasso/helm-charts)

## Migrating an existing manifest installation

The `removed` block for `kubernetes_manifest.rcprofile_crd` uses `destroy = false`: applying this configuration removes that old resource from OpenTofu state while preserving the live CRD and every stored profile. The plan must show the old resource being forgotten, not destroyed, alongside creation of `helm_release.rcprofile_crd`. Keep the migration block so older platform states can follow the same path. [OpenTofu resource removal](https://opentofu.org/docs/v1.12/language/resources/syntax/#removing-resources)

Helm skips a CRD that already exists and does not upgrade or delete CRDs under a chart's `crds/` directory. Existing installations must already have the intended schema before this migration; installing or upgrading the Helm release does not repair an older CRD. Fresh installations receive the CRD from chart `0.1.1`. Subsequent CRD schema upgrades require a separate explicit upgrade procedure. [Helm CRD lifecycle](https://helm.sh/docs/chart_best_practices/custom_resource_definitions/)

## Profile publisher for GitHub Actions

`publisher.tf` gives the repository's workflow the only credentials it needs to submit RCProfiles:

| Resource | Purpose |
| --- | --- |
| GitHub OIDC provider | Lets AWS verify GitHub Actions tokens. One per AWS account; `create_github_oidc_provider = false` reuses an existing one. |
| `rcprofile-publisher-github` role | Assumable only by `github_repository` on `github_deployment_branch`; may only invoke the publisher Lambda. |
| `rcprofile-publisher` Lambda | Runs in the management cluster's subnets and applies the submitted profile with server-side apply, adding the `demo.runtimeconditions.io/image` annotation. Reapplying a profile name updates the same resource. |
| EKS access entry, Role, RoleBinding | Limit the Lambda to get/create/patch on RCProfiles in the profile namespace. |

Additional inputs: `github_repository` (`owner/name`), `github_deployment_branch` (default `main`), `create_github_oidc_provider` (default `true`), and `publisher_security_group_id`. Set `github_repository` in your `default.tfvars` to the GitHub repository whose workflow publishes profiles; it has no default. Foundation creates the security group and exposes it:

```sh
export TF_VAR_publisher_security_group_id="$(tofu -chdir=../foundation output -raw profile_publisher_security_group_id)"
```

Apply foundation first so its new output exists. After applying this root, copy the `github_actions` output into the repository's **Settings → Secrets and variables → Actions → Variables** as `PUBLISHER_ROLE_ARN`, `PUBLISHER_FUNCTION_NAME`, and `AWS_REGION`. These are identifiers, not secrets.

The OIDC provider created here is account-wide; destroying this root removes it for every other stack that uses it.

The workflow pushes the image to `ghcr.io/<owner>/<repository>`. GitHub creates a new package as private, and a workflow cannot change that. After the first push, open the package's **Package settings** and change its visibility to **Public** once. Later pushes keep it public.

## Subsequent batches

1. Install the approved EBS CSI and EKS Pod Identity add-ons, their scoped IAM permissions, and gp3 storage classes for the workload clusters. Pin add-on versions compatible with each cluster.
2. Install separate persistent NATS deployments after agreeing broker count, volume sizes, authentication, TLS, and credential ownership.
3. Select the Kratix state store and means of applying generated manifests to dev and production. Register their Destinations after the Kratix CRDs exist.
4. Implement the watcher adapter and environment Promise/workflows for NATS, SMTP, and PostgreSQL in a later root. Applying RCProfiles has no provisioning effect until that adapter and Promise are installed.

Retain the existing AWS VPC CNI and kube-proxy. The demo's application conditions cover NATS, SMTP, and PostgreSQL.

Kratix's sample SeaweedFS state store, credentials, and example Destinations are disabled. This initial root installs controllers without choosing a delivery backend. Custom resources using newly installed CRDs belong in a later plan/apply so Kubernetes schema discovery can succeed.

Before cluster teardown, remove workflow-owned application resources and support services, then destroy platform resources while the Kubernetes APIs remain reachable. Destroy the foundation last.
