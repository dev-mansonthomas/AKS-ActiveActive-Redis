# Chaos web console — slices 1 and 2

**Status: implemented 2026-11-26** (tests green: `./tests/run.sh`; not yet validated on real clusters, see `docs/TODO.md` §O).
Deviations from the plan: `urllib3==2.7.0` (aligned with `redis-enterprise-testing`), pytest 9.2.0, `RE_CONFIG_FILE` and
`DEBUG_DIR` overrides added to `common/` so tests need no real config, `region` step names kept (`region-nodes`,
`region-db`, `region-recovery` = total), `CHAOS_DEGRADE_WAIT` env to shorten the "degradation observed" wait in tests.

Source: `docs/product/brief.md` (2026-11-26). Supersedes the "launch" and "banner" parts of
`docs/specs/demo-console.md`; the existing data routes are kept (their robustness is covered here,
new indicators and the Redis skin are slices 3-4, out of scope).

**Owner files**
- new: `chaos-webui-start.sh`, `chaos-webui-stop.sh` (repo root; `git mv launch-flask-console.sh chaos-webui-start.sh`, delete `scripts/launch-flask-console.sh`)
- new: `flask/chaos_state.py` (run state machine), `flask/scenarios.py` (texts), `flask/tests/`
- edit: `flask/app.py`, `flask/templates/index.html`, `flask/requirements.txt`, `scripts/chaos.sh`
- docs to update when done: `README.md`, `CLAUDE.md` §4/§5, `docs/TODO.md`, `docs/architecture/overview.md`, `docs/specs/demo-console.md`, ADR 0009 mention

## Purpose

The presenter shares the console over video while `scripts/chaos.sh` breaks things. The console
must (1) start and stop with one quiet command each, never writing HTTP logs to the terminal, and
(2) be told by `chaos.sh` which scenario is running, then show what is simulated, what the audience
should expect, a running timer, and a step-by-step timeline with PASS/FAIL and recovery times.
The console is a display only: no control of the experiment from the browser.

## User stories / acceptance criteria

### Slice 1 — launcher
- As the presenter, I run `./chaos-webui-start.sh` and the only thing printed is one line with the URL, PID and log path.
  - [ ] Given no console running, when I run start, then stdout is exactly one line `Chaos console: http://127.0.0.1:<port>/  (pid <n>, log debug/chaos-webui-<ts>.log)` and the command returns in < 15 s.
  - [ ] Given the console is running and receives requests, then nothing is written to the terminal that started it; request lines appear only in `debug/chaos-webui-*.log`.
  - [ ] Given it is already running (PID file valid and `/api/health` answers), when I run start again, then it prints the same one-liner, starts nothing, exits 0.
  - [ ] Given the server cannot become healthy within 10 s, then start prints the last 20 log lines to stderr and exits 1, leaving no stale PID file.
- As the presenter, I run `./chaos-webui-stop.sh` to stop it.
  - [ ] Given it runs, when I stop, then the process is gone, the PID file removed, exit 0, one line `stopped (pid <n>)`.
  - [ ] Given nothing runs, then stop prints `not running`, exits 0.
  - [ ] Given the PID file points to a process whose command line does not contain `flask/app.py`, then stop refuses to kill it, removes the stale file, exits 0 with a warning.
- Safety
  - [ ] The server binds `127.0.0.1` only, `debug=False`, `use_reloader=False` (no Werkzeug debugger).
  - [ ] Both scripts run from any CWD, are `chmod 700`, and pass `shellcheck -S warning`.
  - [ ] `grep -r launch-flask-console` finds nothing outside `docs/archive/` and ADR history.

### Slice 2a — `chaos.sh` scenario selection (added 2026-11-26)
- As the presenter, I run only the scenario I want, and resume after an interruption (network drop, Mac asleep).
  - [ ] `./scripts/chaos.sh --list` prints one line per scenario (`id  title — what is played`) for `pod`, `node`, `region`, `region-recover`, needs no cloud call, writes no log, exits 0.
  - [ ] `./scripts/chaos.sh --scenario node` runs the health gate then only the node scenario; `--scenario pod,node` runs those two in the canonical order; no option = `pod,node,region` (today's behaviour).
  - [ ] An unknown id exits 2 and prints the valid ids.
  - [ ] `--scenario region-recover` plays only the recovery of a region left down or half-recovered (nodes back to `GCP_NODE_COUNT`/autoscaling restored, `clusterRecovery`, `rladmin recover all`, wait, data check). It **skips the health gate** (the cluster is degraded by definition) and says so; every other scenario keeps the gate.
  - [ ] Works with `--no-prompt`, `<cluster-name>` and `--check-only` as before; `--check-only` ignores `--scenario`.
- As the presenter, I drive the demo step by step.
  - [ ] In interactive mode the console shows the next scenario as **Ready — waiting for the presenter** (`phase_start` is sent *before* the "Press Enter" prompt); the timer starts only at `inject`.
  - [ ] The banner lists the actions that will be played (from `scenarios.py: actions`) at scenario start, and at `inject` shows the exact action just played (e.g. `kubectl delete pod rec-a-0 --force`, `gcloud compute instances reset <vm> --zone <z>`, `resize pool to 0 + force-delete REC pods`) and logs it in the timeline.

### Slice 2b — which pod is killed (added 2026-11-26 after the first real run)
Observed on GCP: `rec-a-0` was cluster primary, database primary shard AND endpoint holder; deleting it took the REST API
and the endpoint of region A down while the other nodes elected a primary. That is the worst case, not "a pod failure".
- [x] Default victim of `pod` (and VM of `node`): RE node 2 (pod index 1) — never the cluster primary (we would lose the cluster API) nor the endpoint holder; whether it holds the primary or the replica shard does not matter. If node 2 is not eligible after a failover, another replica holding a shard. Parsed from `rladmin status`, so a failover cannot make the script kill the primary.
- [x] `--pod <index|name>` forces the victim (`--pod 0` = the primary pod, worst case, on request); invalid or other-cluster pod exits 2.
- [x] The chosen pod and its role are printed, sent in the `inject` note, and used by `node` (VM hosting that pod).

### Slice 2c — audit trail (added 2026-11-27, after reading the first real `region` log)

A run must be auditable from its files alone, without the presenter's memory.
- [x] `debug/chaos-<ts>.log` header: git revision (+uncommitted), kubectl/gcloud versions, config, `CHAOS_*` env.
- [x] `debug/chaos-<ts>.events.jsonl`: one JSON object per line (`ts` UTC, `t` seconds since start, `type`), fed by `chaos_notify_hook`, so it holds exactly what the console received plus `cmd_start/cmd_end` (command, rc, duration), `sample`, `progress`, `prompt` (how long the presenter waited), `snapshot`.
- [x] Every cloud/cluster command is bracketed by `▶ …` / `◀ … rc=N in Ns`.
- [x] `[sample:<label>]` lines: Ready/total nodes, Running/total pods, GCE instances of the cluster, every ~10 s during an outage wait; the witness REC state in every 30 s progress line.
- [x] Snapshots add: REAADB `.status`, operator log tail, `crdb-cli crdb list`, GKE operations and GCE instances (both clusters).
- [x] `region-injected` check: after the outage, Kubernetes must answer with **0 nodes**, else FAIL. (2026-11-26: the instance wait matched no VM — names hold a truncated cluster name — and passed at once; the log then showed 3 Ready nodes aged 112 s right after "no nodes left".) GCE instances are now found by label `goog-k8s-cluster-name`.
- [x] Health gate starts with the cloud login (`gcloud auth print-access-token`); if it lapsed it prints `gcloud auth login <GCP_ACCOUNT>` and exits 3. `node`, `region` and `region-recover` re-check it right before touching the cloud. If the region injection is not confirmed, the node pool is restored (size + autoscaling) before stopping.
- [x] Closing `RESULT run=… failed=N duration=…s events=…` line.

### Slice 2 — scenario channel and banner
- As `chaos.sh`, I notify the console of run/phase/step events and never fail or slow down because of it.
  - [ ] Given the console is down, when `chaos.sh` sends an event, then it returns within 2 s, the run continues, and at most one line about the console is written to the chaos log.
- As the presenter, I see at a glance which scenario runs and what to expect.
  - [ ] Given a `phase_start` for `pod|node|region`, then the banner shows that scenario's title, "What we simulate", and "What to expect" (texts from `flask/scenarios.py`) within 2 s.
  - [ ] Given an `inject` event, then a timer starts at 00:00 and counts up in `mm:ss` until `phase_end`; when the step `*-recovery` arrives, the timer freezes and shows `Recovered in <n> s`.
  - [ ] Given `step` events, then the timeline lists them in arrival order with a PASS (green), FAIL (red) or INFO (neutral) badge and the duration when given.
  - [ ] Given `run_end`, then a final line shows overall PASS/FAIL and the count of failed checks; the banner stays until the next `run_start`.
  - [ ] Given no run, then the banner says `No chaos run in progress` and, if a previous run exists, its result and finish time.
- As the presenter, I can trust what I see while a region is down.
  - [ ] Given a region is unreachable, then its indicators show `unreachable` with the age of the last good value within 10 s, and the other region keeps updating.
  - [ ] Each data route returns (JSON, never an HTML 500) within 4 s even if the backend hangs.
  - [ ] Event data is rendered with `textContent` only (no HTML injection).
- Refresh policy
  - [ ] The page runs one sequential loop per source (`redis/<r1>`, `redis/<r2>`, `redisha`, `cluster/<r1>`, `cluster/<r2>`, `chaos state`): the next request starts only after the previous one finished or timed out (8 s client timeout), never overlapping on the same source.
  - [ ] During an active run each loop re-requests as soon as possible but at most once per second per source; with no active run, data loops wait 10 s between requests. The chaos-state loop polls every 1 s always (in-memory, no external command).
  - [ ] Each indicator shows the age of its value (`updated 3 s ago`).
- `chaos.sh` offers the console
  - [ ] Given interactive mode and the console not running, when `chaos.sh` starts, then it asks `Start the chaos console now? [y/N]`; `y` runs `chaos-webui-start.sh`. In `--no-prompt` mode it only logs a one-line hint and continues.

## Inputs & outputs

### Config
`CHAOS_WEBUI_PORT` (default **5050**; 5000 is taken by macOS AirPlay Receiver on recent macOS). Read by start/stop, `app.py`, `chaos.sh`.
Files (all under gitignored `debug/`): `chaos-webui.pid` (`<pid> <port>`), `chaos-webui-<ts>.log` + `chaos-webui-latest.log` symlink.

### HTTP API (all JSON, localhost only)
| Route | Method | Purpose |
|---|---|---|
| `/api/health` | GET | `{"status":"ok"}` — used by start script |
| `/api/chaos/event` | POST | `chaos.sh` → console |
| `/api/chaos/state` | GET | page → console |
| existing: `/`, `/redis/<region>`, `/redisha`, `/cluster/<region>` | GET | unchanged contracts, hardened |

Event body (`Content-Type: application/json`, ≤ 4 KB; unknown keys ignored):
```json
{ "type": "run_start|phase_start|inject|step|phase_end|run_end",
  "run_id": "20261126-171505",            // required, [A-Za-z0-9._-]{1,40}
  "phase": "health|pod|node|region",      // required for phase_start/inject/step/phase_end
  "target": "rec-a", "witness": "rec-b",  // run_start
  "name": "pod-recovery",                 // step: record() name
  "status": "PASS|FAIL|INFO",             // step, phase_end, run_end (run_end also ABORTED)
  "seconds": 42,                          // step, optional number >= 0
  "note": "free text, clipped to 200 chars" }
```
Responses: `204` accepted; `400` invalid JSON/schema (body `{"error": "..."}`); `403` non-local client; `413` too large.

State (`GET /api/chaos/state`):
```json
{ "server_time": 1795700000.0,
  "active": true,
  "run": { "run_id": "...", "target": "rec-a", "witness": "rec-b", "started_at": 0.0,
           "phase": "node", "phase_started_at": 0.0, "injected_at": 0.0, "recovered_seconds": null,
           "status": "RUNNING|PASS|FAIL|ABORTED|STALE", "finished_at": null, "failed": 0,
           "steps": [ {"t": 0.0, "phase": "health", "name": "health-check", "status": "PASS", "seconds": 0, "note": ""} ],
           "awaiting_operator": true,
           "scenario": { "title": "...", "simulate": "...", "actions": ["..."], "expect": "...", "typical": null } } }
```
`run` is `null` before the first run. Times are epoch seconds from the server clock; the page computes the timer with `server_time` offset.

### `flask/scenarios.py`
`SCENARIOS = {"health": {...}, "pod": {...}, "node": {...}, "region": {...}}`, each with `title`, `simulate`, `actions` (ordered list of the concrete steps `chaos.sh` will play, in plain words), `expect`, `typical` (null until measured). Ids shared with `chaos.sh --scenario`: `pod`, `node`, `region`, `region-recover` (plus `health`, not selectable). English by default (open question below). Content, to be refined after the first real run:
- **pod** — simulate: one Redis Enterprise pod is force-deleted. expect: Kubernetes recreates it, the node rejoins the cluster, the database stays available in both regions, no human action.
- **node** — simulate: a cloud VM running a Redis Enterprise node is hard-reset. expect: the node goes down then OK again once the VM and pod return; shards fail over inside the cluster; the database keeps serving; no human action.
- **region** — simulate: every node of one region is removed. expect: the other region keeps serving reads and writes (Active-Active); when nodes return, the recovery procedure (cluster recovery + database recovery, issued by `chaos.sh`) restores the region and replication catches up. Say plainly that total-loss recovery is *not* fully automatic.
- **health** — the pre-flight: both clusters and the database healthy before anything is broken.

## Behavior & edge cases

**Run state machine** (`flask/chaos_state.py`, in memory, one lock, last run only, ≤ 200 steps kept):
- `run_start` replaces any previous run; a previous `RUNNING` run is stored as `ABORTED`.
- `phase_start` sets `phase`; `phase_start` sets `awaiting_operator=true`; `inject` sets `injected_at` (timer origin), clears `awaiting_operator`, and its `note` carries the exact action played; a `step` whose `name` ends in `-recovery` (PASS) sets `recovered_seconds` from `seconds`.
- Lenient ordering: an event for an unknown `run_id` (console restarted mid-run) implicitly creates the run; a `step` before `phase_start` is accepted.
- `run_end` sets status; `status` `FAIL` if any step FAIL.
- No event for 30 min while `RUNNING` → reported `STALE` by `GET /api/chaos/state` (computed, not stored).
- Never raises to the client for state problems; malformed input → 400 only.

**Security:** non-loopback `request.remote_addr` → 403 on `/api/chaos/event`. `MAX_CONTENT_LENGTH = 4096`. Page builds DOM with `textContent` (the existing `.append("<span …>"+data.message…)` pattern is replaced). The DB password is read as today from the K8s secret and never logged or returned.

**Data routes hardening:** every outbound call has a timeout ≤ 2 s (`/v1/shards` has none today); exceptions map to `{"message": "Error: …"}` with HTTP 200; `get_cluster` iterates the nodes returned (today the page loops `node_1..node_3` and throws if a node is missing).

**Launcher details**
- `start`: `cd` to the repo root; Python = `$REPO_ROOT/.venv/bin/python`, else `redis-enterprise-testing/.venv/bin/python`, else create `$REPO_ROOT/.venv` and `pip install -r flask/requirements.txt` (progress to the log, one line to stdout); starts `python flask/app.py` detached (`nohup`, own session), stdout+stderr to the log; polls `/api/health` for 10 s; on macOS opens the URL unless `--no-open`.
- `stop`: SIGTERM, wait 5 s, SIGKILL if needed. Looks up the PID by file, falls back to the listener on `CHAOS_WEBUI_PORT` only if its command line contains `flask/app.py`.
- `flask/requirements.txt` gains `requests==2.34.2` and `urllib3==2.7.0` (imported by `app.py`, currently undeclared).

**`chaos.sh` options** (parsed before `re_log_init`, `re_load_config` only; `--list` must not touch the cloud):
`--list` · `--scenario <id[,id...]>` · `--no-prompt` · `--check-only` · `<cluster-name>`. Phases become independently callable (`phase_pod`, `phase_node`, `phase_region`, `phase_region_recover`); `phase_region` = inject outage + survivor check + `phase_region_recover`. The EXIT trap and `run_end` carry the list of scenarios played.

**`chaos.sh` hooks** (function `notify`, best effort):
```
notify <type> [key=value ...]  →  curl -s -m 2 -o /dev/null -X POST http://127.0.0.1:${CHAOS_WEBUI_PORT:-5050}/api/chaos/event -H 'Content-Type: application/json' -d '<json>'
```
JSON is built with a small escaper (backslash, quote, control characters). Failures are swallowed; the first failure writes one log line. Hooks: `run_start` (after arg parsing, `run_id=$RUN_ID`), `phase_start`/`phase_end` in each `phase_*` and the health gate, `inject` right where the failure is applied (pod delete, VM reset, region resize), `step` inside `record()` (so every PASS/FAIL already recorded is sent), `run_end` before exit (also from the health-gate exit 3 and an EXIT trap so an aborted run ends `ABORTED`).

**Edge cases**
| Case | Expected |
|---|---|
| Port already used by another program | start: not healthy in 10 s → stderr shows log tail, exit 1; stale PID file removed |
| Start run twice concurrently | second sees valid PID file → prints the line, exit 0 |
| Console restarted mid-run | state lost; next event recreates the run implicitly |
| `chaos.sh` killed (Ctrl+C) | EXIT trap sends `run_end ABORTED`; if even that fails, `STALE` after 30 min |
| Event from another host / huge body / bad JSON | 403 / 413 / 400, state unchanged |
| Page opened with no run | idle banner |
| Region down | its data loops time out at 8 s client-side, 4 s server-side; indicator `unreachable`, last value age shown |
| Interrupted mid-region (pool left at 0) | `--scenario region-recover` brings it back; without it the health gate refuses any other scenario and prints the restore command |
| `--scenario` with a scenario that needs a healthy target while the other cluster is degraded | health gate (both clusters) refuses, lists problems, exit 3 |
| Two browsers | both fine (stateless reads) |
| Clock skew browser/server | timer uses `server_time` offset |

## Out of scope
Redis skin and layout for 1800x1169 (slice 3), new indicators — nodes/pods/lag/ops/s (slice 4), mock-data mode (needed by slice 3), convergence check, SSE, history charts, authentication, remote access, starting chaos from the browser, localization, pytest in CI.

## Test plan
No test suite exists today; this adds `flask/tests/` (pytest, `flask/requirements-dev.txt`; pin the current stable pytest after checking it with Context7 at implementation time).
- **Unit (`chaos_state`)**: transitions (start→phase→inject→step→end), abort on new run_start, implicit run for unknown id, `-recovery` freezes timer, FAIL propagation, STALE after 30 min (injected clock), 200-step cap.
- **API (Flask test client)**: 204 on valid events; 400 on bad JSON / missing run_id / bad type / bad run_id charset; 413 on > 4 KB; 403 when `remote_addr` is not loopback; unknown keys ignored; `note` clipped to 200 chars; `GET /api/chaos/state` shape; `/api/health`.
- **Routes hardening**: with `requests.get` patched to hang/raise, `/cluster/<region>` returns JSON `{"message": ...}` within 4 s; unknown region → 404.
- **Launcher (bash, in the VM — the app starts without any cluster)**: start prints exactly one line; request lines go only to the log; second start is idempotent; stop kills and removes PID file; stop with stale/foreign PID refuses; start with port busy exits 1 with log tail; `shellcheck -S warning`; `ls -l` shows `rwx------`.
- **chaos.sh options (bash, stubbed `kubectl`/`gcloud` as in the VM harness)**: `--list` output and exit 0 with no cloud CLI present; unknown id → exit 2 with valid ids; `--scenario node` runs only the node phase (assert via the events posted to a local test server); `pod,node` order is canonical whatever the input order; `region-recover` skips the gate; `--check-only` ignores `--scenario`.
- **`notify` (bash)**: sourced function against the live test server posts a full run and `/api/chaos/state` reflects it; with the server down it returns < 2 s and does not change the exit status; JSON escaping with quotes/newlines in `note`.
- **Page (Playwright, VM)**: post a scripted sequence of events, screenshot idle / running / PASS / FAIL banners at 1800x1169, assert timer text and timeline rows; post `note` = `<img src=x onerror=alert(1)>` and assert it appears as text, no dialog; assert request spacing (≤ 1/s per source) from the network log.
- **E2E on the host (manual, tonight)**: `./scripts/chaos.sh --check-only`, then a full run with the console open; compare timeline with `debug/chaos-latest.log`.

## Dependencies & risks
- Flask 3.1.3 (pinned), `redis==8.1.0`, `kubernetes==36.0.3` (already), `requests==2.34.2` and `urllib3==2.7.0` to add; `curl` on the host (present on macOS). Playwright and `shellcheck` are in the VM.
- Riskiest: the **browser polling model** (sequential loops with timeouts, correct "unreachable" handling on a half-dead region) and **`chaos.sh` hook placement** (an event must never block or fail the run; `set -e` and `pipefail` interact with `curl`). Second: macOS port 5000 conflict (hence 5050). Third: the page currently depends on CDN jQuery/Bootstrap; slice 3 will replace it, slice 2 keeps it.
- Open: UI language (English default, French needs a second dictionary); whether `typical` durations should be filled after the first real run; whether the console should refuse start when `config.sh` is missing (currently `Config()` raises at import → start reports the log tail).

Next: `/plan-feature chaos-webui` (slices 1-2).
