# Feature specs

Agent-facing contracts, derived **from the code** (`scripts/`, `providers/`, `common/`,
`templates/`, `flask/`, `redis-enterprise-testing/`) on **2026-09-04**.

Most specs below were written on 2026-09-04 and carry a **"Current state"** block (2026-11-27) that
supersedes their older "Known defects" wherever the two conflict. A credential-free test suite exists
(`./tests/run.sh`, covering the console and `chaos.sh`); there is still **no CI**. Anything marked
**(inferred — verify)** could not be confirmed without cloud credentials, which are unavailable in the VM.

| Spec | Feature | Status |
|---|---|---|
| [`cloud-provider-abstraction.md`](cloud-provider-abstraction.md) | `config.sh` + provider dispatch | implemented for steps 01–05 and teardown |
| [`cluster-provisioning.md`](cluster-provisioning.md) | Step 01 — Terraform per cloud | GCP ✅ · AWS validates · Azure not re-verified |
| [`redis-enterprise-bootstrap.md`](redis-enterprise-bootstrap.md) | Step 02 — ingress, operator, REC, DNS | ✅ GCP (02a, parallel) |
| [`active-active-database.md`](active-active-database.md) | Steps 03–05 — RERC trust + AA DB | ✅ GCP (client access automated) |
| [`dns-management.md`](dns-management.md) | Wildcard DNS per cluster | GCP ✅ · AWS A records only · Azure inline |
| [`tag-compliance.md`](tag-compliance.md) | `owner` / `skip_deletion` audit | ✅ all 3 clouds |
| [`chaos-engineering.md`](chaos-engineering.md) | Outage/HA harness | ✅ GCP (4 scenarios) · Azure unverified |
| [`load-testing.md`](load-testing.md) | Load generation + latency benchmark | works (cloud-agnostic) |
| [`demo-console.md`](demo-console.md) | Flask per-region console | v2 implemented (see `chaos-webui.md`) |
| [`teardown.md`](teardown.md) | `delete-all-resources.sh` | ✅ GCP |
| [`chaos-webui.md`](chaos-webui.md) | Chaos web console, event channel, audit trail | ✅ implemented (slices 1–2c) |
