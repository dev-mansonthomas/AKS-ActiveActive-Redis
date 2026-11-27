# GCP — identities, roles and one-off IAM setup

Audience: whoever prepares a GCP project for this rig (an IAM admin for §2, then the
operator who runs `./gcp-deploy.sh`). Everything here is derived from what the code actually
calls; the preflight (`./gcp-deploy.sh --plan-only`) re-checks it before anything is created.

**Design rule:** the identity that deploys can create and destroy infrastructure, but it can
**not** create service accounts or edit IAM (`resourcemanager.projects.setIamPolicy` is a
privilege-escalation right: whoever holds it can grant themselves anything). The one thing that
needs IAM rights — the service account the GKE nodes run as — is created **once, by an IAM
admin**, then only *referenced* by the deploy (`GCP_NODE_SERVICE_ACCOUNT` in `config.sh`).

## 1. The three identities

| Identity | Used by | What it is |
|---|---|---|
| **gcloud account** (`GCP_ACCOUNT` in `config.sh`) | `gcloud`, `kubectl` (GKE auth plugin), DNS records, teardown | e.g. `tmanson-re-vm-sa@<project>.iam.gserviceaccount.com` |
| **Application Default Credentials (ADC)** | the OpenTofu `google` provider **only** | whatever `gcloud auth application-default login` or `GOOGLE_APPLICATION_CREDENTIALS` points to. Switching the gcloud account does **not** switch ADC. |
| **Node service account** (`GCP_NODE_SERVICE_ACCOUNT`) | the GKE nodes themselves | `gke-nodes@<project>.iam.gserviceaccount.com` — dedicated, least privilege |

Both the gcloud account and the ADC identity need the roles in §3 (they may be the same SA).

## 2. One-off setup — `./gcp-setup.sh` (run before the first deploy)

Driven by `config.sh` (`GCP_PROJECT_ID`, `GCP_NODE_SERVICE_ACCOUNT`, `GCP_ACCOUNT`,
`GCP_DEPLOYER_ROLES`, optional `GCP_ADMIN_ACCOUNT`). Run it **on the host, as an IAM admin** —
it refuses to run as the deploy identity. It is idempotent.

```bash
./gcp-setup.sh --dry-run   # prints every gcloud command, changes nothing: review it
./gcp-setup.sh             # applies
./gcp-deploy.sh --plan-only
```

What it does (the equivalent manual commands, for review):

```bash
P=<project>; DEPLOYER=<GCP_ACCOUNT>; NODE_SA=gke-nodes@$P.iam.gserviceaccount.com

# 1. the node service account (skipped if it exists)
gcloud iam service-accounts create gke-nodes --project "$P" \
  --display-name "GKE nodes (Redis Active-Active demo)"

# 2. least-privilege runtime role for nodes (logging, monitoring, metadata, image pull)
gcloud projects add-iam-policy-binding "$P" --member="serviceAccount:$NODE_SA" \
  --role="roles/container.defaultNodeServiceAccount" --condition=None --format=none

# 3. let the deploy identity attach it to nodes (actAs) - on THIS service account only
gcloud iam service-accounts add-iam-policy-binding "$NODE_SA" --project "$P" \
  --member="serviceAccount:$DEPLOYER" --role="roles/iam.serviceAccountUser"

# 4. each role of GCP_DEPLOYER_ROLES (§3) on the project, for the deploy identity
gcloud projects add-iam-policy-binding "$P" --member="serviceAccount:$DEPLOYER" \
  --role="roles/compute.admin" --condition=None --format=none     # ...and container.admin, dns.admin
```

Needs `iam.serviceAccounts.create` and IAM-policy rights on the project — i.e. a human admin,
**not** the deploy identity.

Notes
- The node SA is **not** managed by OpenTofu, so `--destroy` leaves it in place. That is
  intended: it is reusable by every demo in the project. Remove it only when retiring the project:
  `gcloud iam service-accounts delete "$NODE_SA" --project "$P"`.
- Changing the node SA of an **existing** cluster forces a node-pool replacement. Destroy the old
  demo first (`./gcp-deploy.sh --destroy`), then deploy.
- If the node images are ever pulled from a **private** Artifact Registry, add
  `roles/artifactregistry.reader` to the node SA. Today every image is public.

## 3. Roles the deploy identity needs

Granted by an admin on the **project**, to both the gcloud account and the ADC identity.

| Role | Why (what calls it) | Required |
|---|---|---|
| `roles/compute.admin` | VPC, subnets, firewalls (OpenTofu); GKE-created LB forwarding rules and disks; teardown cleaning orphan firewalls and `pvc-*` disks | yes |
| `roles/container.admin` | create / get / delete the GKE clusters and node pools; `kubectl` RBAC bootstrap | yes |
| `roles/dns.admin` | wildcard `*.<rec>.<zone>` records (step 02) and their deletion (teardown) | yes |
| `roles/iam.serviceAccountUser` **on the node SA only** (§2 step 3) | `iam.serviceAccounts.actAs` when GKE attaches the node SA | yes |
| `roles/cloudasset.viewer` | `./check-tags.sh` (`gcloud asset search-all-resources`) | audit only (in `GCP_DEPLOYER_ROLES`) |
| `roles/serviceusage.serviceUsageViewer` | preflight "API enabled?" checks (otherwise reported as *cannot verify*, non-blocking) | optional |

The preflight tests exactly these permissions with `testIamPermissions`:
`compute.networks.{create,delete}`, `compute.subnetworks.{create,delete}`,
`compute.firewalls.{create,delete}`, `container.clusters.{create,get,delete}`,
`dns.changes.create`, `dns.resourceRecordSets.{create,delete}`, plus
`iam.serviceAccounts.actAs` on the node SA.

The deploy identity must **not** hold `roles/iam.serviceAccountAdmin`,
`roles/resourcemanager.projectIamAdmin`, `roles/owner` or `roles/editor`.

APIs that must be enabled on the project: `container`, `compute`, `dns`, and `cloudasset`
(for `check-tags.sh`). `./gcp-setup.sh` enables them (`GCP_REQUIRED_APIS`); to check by hand:
`gcloud services list --enabled --project <project> --format="value(config.name)" | grep -xE '(container|compute|dns|cloudasset)\.googleapis\.com'` (expect 4 lines).

## 4. Verify

```bash
# What does an identity hold? (read-only; empty "{}" = none of them)
P=<project>; BODY='{"permissions":["container.clusters.create","dns.changes.create","compute.networks.create"]}'
curl -s -X POST -H "Authorization: Bearer $(gcloud auth print-access-token --account=<deployer>)" \
  -H "Content-Type: application/json" -d "$BODY" \
  "https://cloudresourcemanager.googleapis.com/v1/projects/$P:testIamPermissions"
curl -s -X POST -H "Authorization: Bearer $(gcloud auth application-default print-access-token)" \
  -H "Content-Type: application/json" -d "$BODY" \
  "https://cloudresourcemanager.googleapis.com/v1/projects/$P:testIamPermissions"

# Full check, changes nothing (also verifies the node SA exists and actAs works):
./gcp-deploy.sh --plan-only
```

## 5. Adding another deploy identity (another operator or SA)

1. Grant it the four required roles of §3 (project level, plus `serviceAccountUser` on the node SA).
2. Make sure its **ADC** is set (`gcloud auth application-default login`, or
   `GOOGLE_APPLICATION_CREDENTIALS`) — `gcloud auth login` alone is not enough for OpenTofu.
3. Put its address in `GCP_ACCOUNT` (or leave it empty to auto-detect, see `CLAUDE.md` §6).
4. Run `./gcp-deploy.sh --plan-only`: it names any missing permission and prints the exact
   `gcloud ... add-iam-policy-binding` command to fix it.
