# Spec — Chaos / HA demonstration

**Owner:** `scripts/chaos.sh` (+ `common/chaos-notify.sh`). The console and the event contract are specified in
[`chaos-webui.md`](chaos-webui.md); this file is the behaviour of the harness itself.
**Status (2026-11-27):** ✅ GCP: `pod`, `node`, `region`, `region-recover` run on real clusters. Azure: commands kept verbatim from the original script, not re-verified (no access). AWS: unsupported (exit 1 with a message).
The `providers/*/chaos-provider.sh` files are unused; `chaos.sh` holds its own `provider_*` functions.

## Purpose

Prove the customer-facing claim: with Active-Active, losing a pod, a VM or a whole region does not
interrupt service from the other region and the operator repairs the affected one without human action
on the Redis side.

**Precondition:** both clusters must exist. `chaos.sh` exits 2 when the peer cluster has no kubeconfig context (a single-cluster deployment, `gcp-deploy.sh --single`, cannot run chaos: every scenario needs the witness).

## Inputs

`config.sh` (via `common/lib.sh`), a deployed pair of clusters, cloud CLI logged in on the host.
`CLUSTER` (positional, default `CLUSTER1`); options `--scenario`, `--pod`, `--no-prompt|--yes|-y`,
`--check-only`, `--skip-check`, `--list`; env `CHAOS_TIMEOUT` (900 s per phase), `CHAOS_DEGRADE_WAIT`,
`CHAOS_INJECT_VERIFY_WAIT` (120 s), `CHAOS_AUTOSCALER_SETTLE` (60 s), `CHAOS_WEBUI_PORT`.

## Behaviour

1. **Health gate** (skipped for `region-recover`, or with `--skip-check`): cloud login (prints `gcloud auth login …` if lapsed) → per cluster: API, node pool, nodes Ready, pods Ready, REC state, `rladmin` nodes/databases, RERC Active, REAADB `active` (operator `replicationStatus` ≠ `up` is a warning) → write on one region, read on both. Any failure → exit 3, nothing injected.
2. **`pod`**: force-delete one RE pod, victim chosen from `rladmin status` (never the cluster primary nor the endpoint holder; `--pod` overrides). Wait for degradation, then for pods Running + all RE nodes OK; recovery is timed from the injection. Data check on both regions.
3. **`node`**: hard-reset the VM under that pod (`gcloud compute instances reset` / `az vmss restart`); same waits.
4. **`region`**: GCP — autoscaling off, a pause for the autoscaler to notice, resize the pool to 0 (async), force-delete the RE pods (their grace period is one year and would hang the drain), wait for the GCE instances (found by the `goog-k8s-cluster-name` label) to disappear, then **verify Kubernetes reports 0 nodes** (`region-injected`). The surviving region must serve a write/read. Then: restore the pool (size + autoscaling), `spec.clusterRecovery=true` on the REC, wait for the RE nodes, `rladmin recover all`, wait for the databases, data check on both regions. If the injection is not confirmed the pool is restored and the run fails. Azure — `az aks stop` / `az aks start`.
5. **`region-recover`**: the recovery half of `region`, for a region left down; no health gate; no-op on a healthy cluster.

## Outputs

- Console lines (summary), exit code: `0` ok · `1` a check failed · `2` usage · `3` health gate failed.
- `debug/chaos-<ts>.log` (+ `chaos-latest.log`): header (git revision, kubectl/gcloud versions, config), every cloud command as `▶ … / ◀ … rc=N in Ns`, `[sample:<label>]` lines (nodes Ready/total, pods Running/total, GCE instances), progress lines with the witness cluster's state, snapshots (`kubectl get nodes/pods/rec/rerc/reaadb/events`, REAADB status, operator log tail, `rladmin status`, `crdb-cli crdb list`, GKE operations, node pool, cluster-autoscaler status) of **both** clusters, closing `RESULT run=… failed=N duration=…s`.
- `debug/chaos-<ts>.events.jsonl`: one JSON object per event (`ts`, `t` seconds since start, `type`), the same events the console receives plus command, sample, prompt and snapshot records.

## Edge cases and lessons

- Roles move after failovers: never assume `rec-a-0` is the primary.
- `kubectl exec` into a pod on a rebooting node can hang: every probe is bounded (`run_to`).
- The cloud CLI succeeding proves nothing: on 2026-11-26 the instance wait matched no VM and passed instantly; the check is now made against Kubernetes.
- 2026-11-27: with autoscaling reported off, pods left Pending by the drain still triggered `TriggeredScaleUp` and the pool grew back (nodes replaced, never absent). A 60 s settle before the resize fixed the one run done since; the cause (stale autoscaler configuration) is a hypothesis.
- With `--no-prompt` the region stays down only a few seconds (no presenter pause).
- A replication delay of 23–41 s was measured after `pod` and `node` (1 s after `region`): unexplained (`TODO.md` O).

## Tests

`tests/shell/test_chaos.sh` (stubbed `kubectl`/`gcloud`/`curl`): selection, victim choice, gate, login lapse, injection verification, audit trail, ABORTED on SIGTERM. Run: `./tests/run.sh shell`.
