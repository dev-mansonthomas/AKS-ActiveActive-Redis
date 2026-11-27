# ADR 0013 — A chaos injection must be observed, and the gate must say what is wrong

- **Status:** Accepted 2026-11-27
- **Evidence:** `debug/chaos-20261126-210112.log`, `chaos-20261127-103919.log`, `chaos-20261127-114011.log`; `scripts/chaos.sh` (`verify_region_down`, `preflight_health`).

## Context

The `region` scenario once passed while no region had been removed: the wait for the GCE instances matched
no VM name (GKE truncates the cluster name inside VM names) and returned at once; a later snapshot showed
3 `Ready` nodes aged 112 s. A second run showed the pool regrowing after the resize (nodes replaced, not
removed). A passing test that did not test anything is worse than a failing one. Separately, the operator's
`replicationStatus` stayed `down` while every node was OK and data replicated, and blocked the health gate.

## Decision

1. **The cloud CLI succeeding proves nothing.** After injecting a region outage the harness requires Kubernetes itself to report **0 nodes** (`region-injected`); otherwise it fails and restores the node pool (size and autoscaling).
2. **Hard checks measure behaviour; advisory checks measure opinions.** The gate blocks on the cloud login, nodes, pods, REC state, `rladmin`, RERC, REAADB `active` and a real write/read across both regions. The operator's `replicationStatus` ≠ `up` is a visible warning only.
3. **Every run leaves an audit trail** (`debug/chaos-<ts>.log` and `.events.jsonl`): timed commands, periodic state samples, snapshots of both clusters. A reviewer must be able to say what happened from the files alone.
4. Bounded waits everywhere; interruptions end the run as `ABORTED` and tell the console.

## Consequences

Runs are longer by the snapshots (≈ 15 s each, sent after the recovery event so timers are not affected). Some causes stay hypotheses (the autoscaler settle, the stuck `replicationStatus`) and are recorded as such in `docs/TODO.md` O11/O14 rather than papered over.
