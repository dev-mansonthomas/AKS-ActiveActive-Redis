# ADR 0002 — Abstract clouds behind `providers/<cloud>/` + a `CLOUD_PROVIDER` switch

- **Status:** Accepted, **incompletely implemented**
- **Date:** 2026-05-04 (commit `219453b`, "Phase 1")
- **Evidence:** `providers/{azure,aws,gcp}/`, the `case $CLOUD_PROVIDER` blocks in
  `scripts/01-create-cluster.sh` and `scripts/delete-all-resources.sh`, root `check-tags.sh`.

## Context

The rig was Azure-only. Customers routinely ask for a demo on their own cloud, and the strongest
Active-Active story is cross-cloud. Options considered (per `MULTI_CLOUD_SUPPORT_PLAN.md`):

1. Separate branches or repos per cloud — diverges immediately, triples maintenance.
2. A Terraform module abstraction with a single root module — managed-K8s resources differ too
   much between AKS/EKS/GKE for one clean interface.
3. **One directory per provider plus a dispatch switch in the shell layer.**
4. Crossplane / a higher-level abstraction — far too heavy for a demo rig.

## Decision

Option 3. Each `providers/<cloud>/` exposes a fixed contract: `main.tf`, `variables.tf`,
`outputs.tf`, `get-credentials.sh`, `chaos-provider.sh`. `config.sh` selects the cloud with
`CLOUD_PROVIDER` and normalises `<CLOUD>_*` variables onto generic names. Scripts `cd` into the
selected directory or branch on a `case`.

## Consequences

**Positive** — cloud-specific HCL stays idiomatic; adding a cloud is additive; the
cloud-agnostic Redis Enterprise steps (02–05) could in principle be written once.

**Negative — and this is where it stands today**
- The abstraction was applied to **step 01, teardown and tag-checking only**. Steps 02–05 and
  `chaos.sh` still call `az` directly, so AWS/GCP get clusters and nothing else.
  See `../specs/redis-enterprise-bootstrap.md`.
- The contract is **convention, not enforced**: `providers/*/chaos-provider.sh` and
  `common/dns-{aws,gcp}.sh` satisfy the shape but are never invoked — dead code.
- `TF_VAR_*` pass-through is per-`case`-arm and therefore drifted: GCP's `project_id` is never
  exported (so GCP cannot apply *or* destroy), `aws_account_id` is exported but undeclared, and
  regions/instance types are exported by nobody.
- A single `CLOUD_PROVIDER` per run means **cross-cloud Active-Active is structurally
  impossible**. **Decided 2026-09-04: this is acceptable** — two regions within one cloud is the
  demo, and cross-cloud is a nice-to-have. Revisiting it would mean per-cluster provider
  selection. See ADR 0010.
- `providers/azure/` was created by copying the root files verbatim, including the absence of a
  `required_providers` pin — which is why it now fails `tofu validate`. See ADR 0007.
