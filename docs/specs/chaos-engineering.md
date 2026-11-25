# Spec — Chaos / HA demonstration

**Owner:** `scripts/chaos.sh` (and its legacy root duplicate),
`providers/{azure,aws,gcp}/chaos-provider.sh`.
**Status:** Azure-only. **All three `chaos-provider.sh` files are dead code** — `chaos.sh`
contains zero references to `CLOUD_PROVIDER`.

## Purpose

Prove the customer-facing claim: with Active-Active, losing a node — or an entire region —
does not interrupt writes or lose data.

## Inputs

`CLUSTER1`/`CLUSTER2`, `CLUSTER_RESOURCE_GROUP`, `NS` from `config.sh`; a running Active-Active
deployment; ideally a load generator running concurrently
(`redis-enterprise-testing/continuous_load/`). Interactive: waits for the operator to press
Enter between phases (`wait_for_user`).

## Outputs

Console narration of each phase, REC health before/after (`check_rec_health`), and recovery
confirmation (`wait_for_cluster_to_recover`). Screenshot evidence in `images/outages.png`.

## Behaviour (Azure)

1. `source ../config.sh`, define `wait_for_user`, `check_rec_health`,
   `wait_for_cluster_to_recover`.
2. **Node failure:** locate the VMSS backing a region (`az vmss list | grep -i "$region"`), take
   the first instance (`az vmss list-instances … [0].instanceId`), `az vmss restart`.
3. **Cluster failure:** `az aks stop --name "$region"`, poll `az aks show … powerState.code`
   until stopped; later `az aks start` and poll until `Running`.
4. Between phases, re-check REC health so the audience sees recovery.

## Edge cases

| Case | Behaviour |
|---|---|
| `az vmss list \| grep -i "$region"` matches several VMSS | picks whichever grep returns; brittle table-parsing |
| No VMSS matches | `|| true` swallows it; downstream vars empty |
| Cluster already stopped | `az aks stop` errors |
| Non-interactive run | blocks forever on `read -rp` |
| `CLOUD_PROVIDER=aws`/`gcp` | every `az` call fails; **no dispatch exists** |

## Known defects

- **D1 — Azure-hardcoded (9 `az` calls), zero `CLOUD_PROVIDER` awareness.**
- **D2 — `providers/*/chaos-provider.sh` are never invoked** (verified: no reference in any
  `.sh` file). AWS/GCP node-kill and cluster-resize primitives were written and then orphaned;
  `providers/azure/chaos-provider.sh` has 4 shellcheck warnings.
- **D3 — parses `az vmss list -o table` with `grep`** instead of `--query`/JSON.
- **D4 — always targets instance `[0]`**; cannot choose a node or kill several.
- **D5 — interactive-only**; unusable in CI or unattended demos.
- **D6 — no automated assertion.** The script narrates but never verifies zero data loss —
  proof depends on a human watching the load generator. `README.md`'s own Todo says
  *"chaos.sh: automate every action for HA testing, using config.sh"*.
- **D7 — duplicated at the repo root** (213 lines vs 8692 bytes in `scripts/`), so fixes must be
  applied twice or the duplicate deleted.

## Acceptance criteria

- [ ] `chaos.sh` dispatches to `providers/$CLOUD_PROVIDER/chaos-provider.sh` for every cloud
      primitive; no `az` call remains in `chaos.sh`.
- [ ] Node-termination and full-cluster-outage scenarios work on Azure, AWS and GCP.
- [ ] A non-interactive mode (`--yes`) exists for unattended runs.
- [ ] The script **asserts** the outcome: writes continue and the post-recovery key count /
      counter value matches expectation → non-zero exit on data loss.
- [ ] Node selection is explicit, not `[0]`, and uses `--query`, not `grep` on a table.
- [ ] The root duplicate is deleted.
- [ ] `shellcheck -S warning` clean.
