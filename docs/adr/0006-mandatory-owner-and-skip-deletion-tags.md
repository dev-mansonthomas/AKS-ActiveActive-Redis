# ADR 0006 — Mandate `owner` and `skip_deletion` on every cloud resource

- **Status:** Accepted
- **Date:** 2025, extended to AWS/GCP 2026-05-04
- **Evidence:** `tags`/`labels` blocks in all three `providers/*/main.tf`; `validation` blocks on
  `var.owner` and `var.skip_deletion` in AWS and GCP; root `check-tags.sh` +
  `scripts/check-tags-{azure,aws,gcp}.sh`.

## Context

Redis's internal cloud accounts run automated reapers and cost attribution keyed on tags.
Demo clusters are expensive (3 nodes × 2 regions of 8-vCPU-class machines) and easy to forget.
An untagged cluster is both unattributable and liable to be deleted mid-demo — or to run for
weeks unnoticed.

## Decision

Every provisioned resource carries:
- `owner` = `firstname_lastname`, lowercase (e.g. `thomas_manson`)
- `skip_deletion` = `yes` | `no`

Enforced three ways: at provision time (Terraform `validation` blocks), by construction
(provider-level `default_tags` on AWS / `default_labels` on GCP, per-resource `tags` on Azure),
and by audit (`./check-tags.sh`, which exits non-zero on any failure).

## Consequences

**Positive** — cost attribution works; the reaper spares in-use demos; the audit script is the
one component that is genuinely complete on all three clouds; AWS/GCP `default_tags` /
`default_labels` mean new resources inherit tags automatically.

**Negative — and one is a hard platform limit discovered on 2026-09-07**

- **On GCP, most of what we create CANNOT be labelled.** Verified against the
  google provider 8.1 schema:

  | Resource | Labels |
  |---|---|
  | `google_container_cluster` | ✅ `resource_labels` |
  | `google_compute_network` | ❌ |
  | `google_compute_subnetwork` | ❌ |
  | `google_compute_firewall` | ❌ |
  | `google_container_node_pool` | ❌ |

  So **4 of the 5 GCP resource types carry no `owner`/`skip_deletion` at all**,
  and no amount of Terraform can change that. The decision as originally
  written ("every provisioned resource carries…") was unachievable on GCP.

  **Consequence:** on a shared project, the VPC, subnets, firewall rules and
  node pools are attributable **only by their name**. That makes
  `CLUSTER_PREFIX` a load-bearing ownership mechanism, not a cosmetic choice —
  which is why `config.sh` now requires it to be unique per operator and
  `gcp-deploy.sh` validates its length. An automated reaper keyed purely on
  labels will not see these resources; one keyed on names will.

  `check-tags.sh` reflects this: clusters are audited by label, everything else
  by name prefix, and the summary says which method was used for what. It also
  reports resources that carry our prefix but are not in the expected set —
  the closest available substitute for a label-based sweep.

  Not yet evaluated: **GCP resource-manager tags** (distinct from labels) do
  support networks and could restore true attribution. Worth investigating if
  reaper integration ever matters.

- **Azure does not validate `owner`'s format** (no `validation` block on the legacy variables),
  so a malformed value passes there and fails on AWS/GCP — inconsistent.
- **`skip_deletion` is advisory only.** `delete-all-resources.sh` destroys resources regardless
  of the tag; it protects against *external* reapers, not against this repo's own teardown.
  Either enforce it or document it as advisory (`../specs/teardown.md` D5).
- GCP uses **labels**, which have stricter character rules than tags — values must stay
  lowercase/underscore-safe.
- Audit coverage is asymmetric across the three clouds (Azure checks the resource group, AWS
  checks IAM roles, GCP checks subnets); there is no shared definition of "all billable
  resources".
