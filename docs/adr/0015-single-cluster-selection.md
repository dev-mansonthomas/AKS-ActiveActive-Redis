# ADR 0015 — Single-cluster deployments: selected by a flag, tracked by the state

- **Status:** Accepted 2026-11-27 (GCP)
- **Evidence:** `common/deploy-lib.sh` (`--single`), `common/lib.sh` (`re_selected_indexes`, `re_clusters_in_state`, `re_selection_guard`), `providers/gcp/main.tf` (`clusters`), `tests/shell/test_{lib,deploy,teardown}.sh`.

## Context

The rig always built two clusters, linked them (RERC) and created an Active-Active database. A plain Redis
Enterprise cluster on one Kubernetes cluster is also wanted (RDI / SQL demos, `docs/TODO.md` K1), at half the cost.

## Decision

- `gcp-deploy.sh --single [1|2]` deploys one cluster (default 1) with its REC; steps 03 (RERC) and 04 (database) are skipped. No option = both, as before.
- The selection is the exported variable **`RE_CLUSTERS`** (`"1 2"`, `"1"`, `"2"`), set by the flag and inherited by every step. It is deliberately **not** in `config.sh`: nothing persistent can drift from reality.
- **The OpenTofu state is the truth for what exists.** `--destroy` takes no flag and removes the clusters found in the state.
- **A selection that would delete a deployed cluster is refused** (`count = 0` destroys it; `--single` while cluster 2 exists, `--destroy` first). Widening (state has 1, run both) is allowed and adds the second cluster.
- Terraform: a `clusters` set variable drives `count` on the two subnets and clusters; `moved {}` blocks keep a live state a no-op. The shared VPC and firewalls are always created.
- GCP only: `aws`/`azure` reject `--single` (exit 2) until their `main.tf` get the same treatment.

## Consequences

**Positive** — one flag, no new config value, no way to forget a flag at destroy time, no silent deletion.
**Negative** — adding or removing one cluster of an existing deployment is not supported (refused, not handled); `chaos.sh` and the console assume two clusters (chaos refuses with an explanation); the name-collision preflight is skipped when the state is not empty, so the second cluster added later is not checked for collisions.
