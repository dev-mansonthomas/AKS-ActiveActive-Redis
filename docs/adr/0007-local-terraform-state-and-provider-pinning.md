# ADR 0007 — Local OpenTofu state, and pin every provider version

- **Status:** Accepted (local state) / **Accepted but violated** (pinning)
- **Date:** local state 2025; pinning introduced with AWS/GCP on 2026-05-04
- **Evidence:** `terraform.tfstate` in the repo root (gitignored), no `backend` block anywhere;
  `required_providers` with `aws ~> 5.0` and `google ~> 5.0`; **no `terraform{}` block at all in
  `providers/azure/main.tf`**; root `.terraform.lock.hcl` pinning azurerm 4.26.0.

## Context

The rig is a disposable single-operator demo. Remote state (blob/S3/GCS + locking) adds setup
cost and a chicken-and-egg bootstrap problem for something meant to be destroyed daily.
Separately, cloud provider majors ship breaking changes on their own schedule.

## Decision

1. **Local state, no remote backend.** State lives beside the provider module and is gitignored.
2. **Every provider version is pinned** via `required_providers`, with `.terraform.lock.hcl`
   committed so a working combination is reproducible.

## Consequences

**Positive (local state)** — nothing to bootstrap; `tofu destroy` is immediate; no state bucket
to pay for or clean up.

**Negative (local state)**
- **Single-operator by construction**: no locking, no sharing. Two people cannot co-own a
  deployment.
- **Losing the state file orphans the infrastructure** — `tofu destroy` can no longer see it and
  the resources leak silently. `check-tags.sh` is then the only way to find them. This is the
  main cost risk of the design.
- No history or drift detection.

**Negative (pinning — the decision was not applied uniformly)**
- `providers/azure/main.tf` is a **verbatim copy of the legacy root `main.tf` with no
  `terraform{}` block**, so azurerm floats to the newest major. It resolved to **5.4.0**, which
  requires a `node_provisioning_profile` block the code does not have, and
  **`tofu validate` now fails**:
  ```
  Error: Insufficient node_provisioning_profile blocks
    on main.tf line 17, in resource "azurerm_kubernetes_cluster" "k8s1"
  ```
  The legacy root path still works **only** because its committed `.terraform.lock.hcl` pins
  azurerm 4.26.0. Copying files forward without the constraint block is what broke the one
  provider that previously worked.
- The AWS/GCP pins (`~> 5.0`, resolved to aws 5.100.0 / google 5.45.2) are already behind current
  majors. Confirm current stable versions via the **Context7 MCP** before bumping — do not
  guess. Bumping majors will require code changes.
- `eks_version = "1.29"` is separately pinned and ageing.

## Follow-up

**Revised 2026-09-04** — the owner's direction is to move *everything* to current versions, and
version research showed **azurerm 5.4.0 is itself the latest release**. So the fix is to go
**forward**, not back:

- Add a pinned `terraform{}` block to `providers/azure/main.tf` at **`azurerm ~> 5.4`** *and* add
  the `node_provisioning_profile` block the 5.x schema requires. Do **not** pin back to
  `~> 4.26` — that would freeze the project on a superseded major.
- Bump the other two, which are genuinely behind: **`google` 5.45.2 → 8.1.0** (three majors) and
  **`aws` 5.100.0 → 6.63.0**. Do the google bump one major at a time with `tofu validate` between
  steps; it touches the same file as the GCP-first work.
- Commit `.terraform.lock.hcl` for all three provider directories.
- Add a `tofu validate` pre-commit hook so a floating provider can never silently break a path
  again — this is what let the Azure regression ship unnoticed.

Full version table: `../TODO.md` §G.
