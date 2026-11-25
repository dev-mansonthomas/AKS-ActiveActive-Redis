# Feature specs

Agent-facing contracts, derived **from the code** (`scripts/`, `providers/`, `common/`,
`templates/`, `flask/`, `redis-enterprise-testing/`) on **2026-09-04**.

⚠ **There is no test suite and no CI in this repo.** No `handover/FEATURES.md` exists either.
So the "acceptance criteria" below are *specifications to build toward*, not descriptions of
passing tests. Anything marked **(inferred — verify)** could not be confirmed without cloud
credentials, which are unavailable in the VM by design.

| Spec | Feature | Status |
|---|---|---|
| [`cloud-provider-abstraction.md`](cloud-provider-abstraction.md) | `config.sh` + provider dispatch | partial — variable wiring broken |
| [`cluster-provisioning.md`](cluster-provisioning.md) | Step 01 — Terraform per cloud | Azure (legacy) works; AWS untested; GCP blocked |
| [`redis-enterprise-bootstrap.md`](redis-enterprise-bootstrap.md) | Step 02 — ingress, operator, REC, DNS | **broken**; Azure-hardcoded |
| [`active-active-database.md`](active-active-database.md) | Steps 03–05 — RERC trust + AA DB | Azure-only, via legacy path |
| [`dns-management.md`](dns-management.md) | Wildcard DNS per cluster | Azure inline; AWS/GCP dead code |
| [`tag-compliance.md`](tag-compliance.md) | `owner` / `skip_deletion` audit | ✅ all 3 clouds |
| [`chaos-engineering.md`](chaos-engineering.md) | Outage/HA harness | Azure-only; providers dead code |
| [`load-testing.md`](load-testing.md) | Load generation + latency benchmark | works (cloud-agnostic) |
| [`demo-console.md`](demo-console.md) | Flask per-region console | works locally |
| [`teardown.md`](teardown.md) | `delete-all-resources.sh` | provider-aware |
