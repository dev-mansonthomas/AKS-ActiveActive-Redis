# ADR 0009 — Root-level entry points, and the legacy duplicates left behind

- **Status:** **Proposed for supersession** — the wrappers are good; the duplicates are a defect
- **Date:** 2026-05-04 (commit `219453b`, "Phase 1")
- **Evidence:** root `create-all.sh`, `delete-all-resources.sh`, `check-tags.sh` delegate into
  `scripts/`; root `01`–`05`, `chaos.sh`, `launch-flask-console.sh`, `recreate.sh`,
  `main.tf`, `variables.tf`, `output.tf` are their own (older) implementations, all still tracked.

## Context

Phase 1 moved the pipeline from the repository root into `scripts/` and the Terraform into
`providers/`. Users (and `README.md`) were accustomed to running `./create-all.sh` from the
root. Backwards compatibility was desirable.

## Decision as implemented

- Add **thin root wrappers** for the common entry points — `create-all.sh` (`cd scripts &&
  ./create-all.sh`), `delete-all-resources.sh`, and `check-tags.sh` (which is the *new*
  multi-cloud dispatcher, sourcing `./scripts/check-tags-<cloud>.sh`).
- **Leave the original scripts in place** at the root rather than deleting them.

## Consequences

**Positive** — `./create-all.sh` still works from the root, as `README.md` documents; the
`check-tags.sh` dispatcher is a genuinely good pattern (shared helpers at the root, per-cloud
detail in `scripts/`).

**Negative — this is now actively harmful**
- **Eight stale Azure-only duplicates are still tracked**: `01`–`05`, `chaos.sh`,
  `launch-flask-console.sh`, `recreate.sh`. `root/02-setup-haproxy.sh` differs from
  `scripts/02-setup-haproxy.sh` by only two lines (`set -e` and the config path), so fixes must
  be made twice, and it is not obvious which file is authoritative.
- **Root `main.tf`/`variables.tf` are byte-identical to `providers/azure/`** — except the root
  has a working `.terraform.lock.hcl`. So the *legacy* path is the only one that works, while
  the *new* path fails `tofu validate` (ADR 0007).
- **`README.md` documents the legacy path**, which means the documented instructions and the
  intended architecture disagree.
- **Two contradictory CWD contracts** now coexist: `scripts/*.sh` expect CWD=`scripts/`, root
  `check-tags.sh` expects CWD=repo root.
- `scripts/check-tags.sh` is itself a stale Azure-only duplicate of the root dispatcher.

## Proposed supersession

1. Keep the three root wrappers (`create-all.sh`, `delete-all-resources.sh`, `check-tags.sh`)
   and add wrappers for `01`–`05`, `chaos.sh`, `launch-flask-console.sh`, `recreate.sh`.
2. **Delete** the eight legacy root implementations, plus root `main.tf`/`variables.tf`/
   `output.tf` and `scripts/check-tags.sh`.
3. First **port the working azurerm 4.26.0 lock** from the root into `providers/azure/` and add
   the `required_providers` pin, so deleting the legacy path does not remove the only functioning
   Azure deployment.
4. Make every script CWD-independent (`cd "$(dirname "$0")/.."`) so the two contracts collapse
   into one.
5. Update `README.md` to the surviving path.

**Do not do step 2 before step 3** — the legacy root Terraform is currently the only Azure
configuration that validates.
