# Spec — Kubernetes cluster provisioning (step 01)

**Owner:** `scripts/01-create-cluster.sh`, `providers/{azure,aws,gcp}/{main,variables,outputs}.tf`,
`providers/*/get-credentials.sh`. Legacy equivalent: root `01-create-cluster.sh` + root `main.tf`.
**Status (2026-11-27):** GCP ✅ applied and destroyed repeatedly on a real project; AWS validates, never applied; Azure not re-verified since the rework (no access).

## Current state (2026-11-27, supersedes the "Known defects" below where they conflict)

- **GCP works.** `TF_VAR_project_id` and every other variable come from `config.sh` through `re_export_tf_vars`; the old D2 ("GCP cannot apply") no longer holds.
- **Node pool is declared inside `google_container_cluster`** (`node_pool {}` per region). A separate `google_container_node_pool` needs the default pool created then deleted first (≈1m40) and a second creation (≈1m30). The gain turned out smaller than estimated; destroy time with the inline pool is still to be measured (`TODO.md` N5).
- Regional clusters with explicit `node_locations` (3 zones, `GCP_NODE_COUNT` is **per zone**); autoscaling `GCP_NODE_MIN_COUNT..MAX_COUNT`.
- Nodes run as a dedicated least-privilege service account (`GCP_NODE_SERVICE_ACCOUNT`, `docs/gcp-iam.md`); the deploy identity may only `actAs` that account.
- `GCP_CLUSTER_TIMEOUT` (default config `90m`): GKE node-pool operations regularly exceed the provider's 40 min default.
- Measured 2026-11-25..27: whole deploy ≈ 13 min, of which cluster creation ≈ 4–5 min.

## Purpose

Create two managed Kubernetes clusters in two regions of the selected cloud, tagged for cost
attribution, and load both into kubeconfig as contexts named after the clusters.

## Inputs

`CLOUD_PROVIDER`, `CLUSTER_RESOURCE_GROUP`, `REGION1`, `REGION2`, `owner`, `skip_deletion` (all
from `config.sh`); an authenticated cloud CLI session on the **host** (`az login` /
`aws sts get-caller-identity` / `gcloud auth login`).

## Outputs

- 2 K8s clusters named `redis-<region1>` and `redis-<region2>`.
- kubeconfig contexts of the **same names** (steps 02–05 do `kubectl config use-context $CLUSTER1`).
- Terraform state in `providers/<cloud>/terraform.tfstate` (local, no remote backend).
- Terraform outputs: cluster endpoints/ARNs/CA certs + a `deployment_summary` (AWS, GCP).

## Behaviour

1. `source ../config.sh`; `cd ../providers/$CLOUD_PROVIDER`.
2. Per-cloud `case` arm: resolve credentials and export `TF_VAR_*`.
3. `tofu init` → `tofu apply -auto-approve`.
4. `./get-credentials.sh` writes the kubeconfig contexts.
5. `cd ../../scripts`.

## Per-cloud resources (verified)

| | Azure | AWS | GCP |
|---|---|---|---|
| Clusters | 2× `azurerm_kubernetes_cluster`, 1 shared `azurerm_resource_group` | 2× `aws_eks_cluster` + 2× `aws_eks_node_group` | 2× `google_container_cluster` + 2× `google_container_node_pool` |
| Network | `kubenet`, `load_balancer_sku=standard` | 2× VPC (`10.0.0.0/16`, `10.1.0.0/16`), public+private subnets, IGW, route tables | 1 global VPC, 1 subnet per region, 2 firewall rules |
| IAM | SystemAssigned identity | 2 roles, 5 managed-policy attachments | default service account |
| Nodes | fixed `node_count = 3` | desired 3, min 2, max 5 | 3/zone, min 2, max 5 |
| K8s version | provider default | `eks_version = "1.29"` | provider default |
| Provider pin | **none** | `aws ~> 5.0` | `google ~> 5.0` |
| `tofu validate` | **FAILS** | passes | passes |

## Edge cases

| Case | Behaviour |
|---|---|
| Cluster already exists | `tofu apply` is idempotent via state; **a deleted/absent state file causes a name-collision failure** |
| `owner` malformed | AWS/GCP fail in a `validation` block; Azure accepts silently |
| Region pair identical | Azure: two clusters with the same derived name in one RG → conflict **(inferred — verify)** |
| Insufficient quota | raw provider error, not caught |
| `tofu apply` partial failure | no cleanup; rerun or `delete-all-resources.sh` |
| GCP project unset | hard failure — see D2 below |

## Known defects

- **D1 — `providers/azure` fails `tofu validate`.** No `terraform{}`/`required_providers`
  block, so azurerm floats to 5.4.0, which requires a `node_provisioning_profile` block:
  *"At least 1 node_provisioning_profile blocks are required"* on both clusters. It is a
  byte-identical copy of the legacy root `main.tf`. The root path works only because its
  committed `.terraform.lock.hcl` pins azurerm **4.26.0**.
- **D2 — GCP cannot apply.** `project_id` is declared with no default and `TF_VAR_project_id`
  is never exported (step 01 only runs `gcloud config set project`). Reproduced:
  `Error: No value for required variable … variables.tf line 7: variable "project_id"`.
- **D3 — regions and instance types are never passed** (no `TF_VAR_region1/region2`, no
  instance-type var). Terraform silently uses its own defaults. See
  [`cloud-provider-abstraction.md`](cloud-provider-abstraction.md) D1/D4.
- **D4 — `TF_VAR_aws_account_id` is exported but declared by no AWS variable** → ignored.
- **D5 — local state, no remote backend, no locking** → single-operator only.
- **D6 — `eks_version = "1.29"`** is pinned and ageing; EKS will eventually refuse it.
- **D7 — GKE/EKS API-server endpoints are public**; no `private_cluster_config` or
  `master_authorized_networks`.
- **D8 — AWS/GCP provider pins (`~> 5.0`) are behind current majors.** Confirm with Context7
  before bumping.

## Acceptance criteria

- [ ] `tofu fmt -check` and `tofu validate` pass for all three provider directories.
- [ ] Every provider pins its provider version explicitly.
- [ ] `CLOUD_PROVIDER=<cloud> ./01-create-cluster.sh` yields 2 clusters in the **regions named
      in `config.sh`**, with the **instance type named in `config.sh`**.
- [ ] kubeconfig contains contexts exactly `redis-<region1>` / `redis-<region2>`.
- [ ] All resources carry `owner` + `skip_deletion` (verified by `./check-tags.sh`).
- [ ] `owner` format is validated identically on all three clouds.
- [ ] Re-running step 01 on an existing deployment is a no-op.
