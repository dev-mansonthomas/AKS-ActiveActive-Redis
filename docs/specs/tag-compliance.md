# Spec — Tag / label compliance audit

**Owner:** root `check-tags.sh` (dispatcher), `scripts/check-tags-{azure,aws,gcp}.sh`.
**Status:** implemented for all three clouds. ⚠️ **On GCP, labels are impossible on 4 of the 5
resource types we create** (see ADR 0006), so ownership there is asserted by **name prefix** for
everything except the clusters. Stale duplicate: `scripts/check-tags.sh` (Azure-only, superseded).

## Purpose

Every billable resource must carry `owner` (`firstname_lastname`) and `skip_deletion`
(`yes`/`no`) so demo infrastructure is attributable and safely reapable. This script audits it.

## Inputs

`CLOUD_PROVIDER`, `owner`, `skip_deletion`, `CLUSTER1`/`CLUSTER2`, `AZURE_*`/`AWS_*`/`GCP_*`
region and group variables from `config.sh`; a read-authenticated cloud CLI.
**Must be run from the repository root** — it sources `./scripts/check-tags-<cloud>.sh`.

## Outputs

Colourised per-resource pass/fail lines, then a summary of `TOTAL_CHECKS`, `PASSED_CHECKS`,
`FAILED_CHECKS`. Exit code 0 when `FAILED_CHECKS == 0` **and** `TOTAL_CHECKS > 0`.

## Behaviour

`check-tags.sh` defines shared counters and a comparison helper, then `case $CLOUD_PROVIDER`
sources the per-cloud script; an unknown provider prints an error and exits 1.

| Cloud | Resources audited |
|---|---|
| Azure | resource group, both AKS clusters, and node/managed resources (8 `az` calls) |
| AWS | both EKS clusters (by ARN), both VPCs, the EKS cluster and node IAM roles (via `aws sts get-caller-identity` for ARNs) |
| GCP | clusters **by label**; VPC, subnets, firewall rules and node pools **by name prefix** (they cannot be labelled); plus a sweep for resources carrying our prefix that are not in the expected set |

## Edge cases

| Case | Behaviour |
|---|---|
| Resource absent | `2>/dev/null` + guard → skipped rather than failed |
| Zero resources found | `TOTAL_CHECKS == 0` → **not** reported as success (guarded) |
| Run from `scripts/` | `source ./scripts/check-tags-*.sh` fails — must run from repo root |
| Tag present, wrong value | reported as a failure with expected vs found |
| GCP label value normalisation | GCP lowercases/restricts labels; `thomas_manson` is valid **(inferred — verify)** |

## Known defects

- **D1 — `scripts/check-tags.sh` is a stale Azure-only duplicate** of the root dispatcher and
  should be deleted (3 shellcheck warnings).
- **D2 — the working-directory contract is the opposite of `scripts/*.sh`** (root vs `scripts/`),
  which is an easy trap.
- **D3 — shellcheck:** root `check-tags.sh` 7 warnings; `check-tags-azure.sh` and
  `check-tags-gcp.sh` 2 each.
- **D4 — no `--fix`/report mode**; findings must be remediated by hand.
- **D6 — ~~hardcoded resource names~~** ✅ fixed 2026-09-07: `check-tags-gcp.sh` looked for a
  literal `redis-vpc` and `check-tags-aws.sh` for `redis-vpc-<region>`, both predating
  `CLUSTER_PREFIX`. They reported the resource as absent while it existed under the prefixed
  name — a **false negative** in audit mode.
- **D7 — ~~coverage was 3 of 9 resources~~** ✅ fixed 2026-09-07: subnets, firewall rules and
  node pools were never audited at all, so `Total checks: 0` was common and made a pass
  meaningless.
- **D8 — GCP attribution is name-based, not label-based**, for everything but the clusters.
  A reaper keyed on labels will not see the network resources. Not a defect we can fix in
  Terraform; possibly addressable with GCP resource-manager *tags* (untested).
- **D5 — coverage is asymmetric** across clouds (Azure audits the RG; AWS audits IAM roles; GCP
  audits subnets) — no shared definition of "all billable resources".

## Acceptance criteria

- [x] Detects a missing or wrong `owner`/`skip_deletion` on every **labellable** resource type.
- [x] Detects resources outside the `CLUSTER_PREFIX` namespace for the types GCP cannot label.
- [x] Reports which method (label vs name) was used, so a pass is not over-read.
- [ ] Evaluate GCP resource-manager tags to restore real attribution on network resources.
- [ ] Exit code 0 only when at least one resource was checked and all passed.
- [ ] Runs correctly from the repository root; ideally CWD-independent.
- [ ] Coverage is defined consistently per cloud.
- [ ] `scripts/check-tags.sh` removed.
- [ ] `shellcheck -S warning` clean.
