# Brief — Chaos web console (Flask) v2

Status: brainstorm 2026-11-26, answers from the product owner. Next: `/spec` on the first slice
(`docs/specs/demo-console.md` already exists for v1 and will be updated, not duplicated).

## Problem

The demo shows Redis Enterprise Active-Active resilience while `scripts/chaos.sh` breaks things
(pod, node, whole region). The current console (`flask/app.py`, 129 lines, written long ago by
someone else) shows only "endpoint available?" and a node/DB status line. It cannot tell the
audience *what is being simulated*, *what to expect*, *how long recovery took*, and the launcher
floods the terminal with HTTP server logs.

## Users and use case

- **One presenter**, sharing a MacBook Pro 13" screen (1800x1169) over video call. One browser, `localhost`.
- Talks step by step: "we now simulate X, expect Y, the operator fixed it with no human action in N seconds."
- The console is a **display**, not a control surface.

## Goals

1. **Redis look and feel** (skills `redis-brand-ui` / `redis-product-ui`), readable when screen-shared:
   large type, high contrast, fits 1800x1169 without scrolling. Web fonts / CDN allowed.
2. **Silent launcher.** `launch-flask-console.sh` → renamed **`chaos-webui-start.sh`** + new
   **`chaos-webui-stop.sh`**. Server logs go to a file under `debug/` (gitignored), never to stdout.
   Start prints the URL and PID only; stop uses the recorded PID.
3. **`chaos.sh` drives the page.** It POSTs scenario events to the console (best effort: if the console
   is not running, chaos.sh continues; in interactive mode it *offers* to start it). The page shows:
   current scenario, **expected behaviour** (text per scenario), elapsed timer, step timeline with
   PASS/FAIL as phases complete (reuses the `record` results chaos.sh already computes), recovery time.
4. **More useful indicators, not more clutter** (present state only, no history charts):
   - per cluster: RE nodes OK/total, K8s nodes Ready, REC pods Ready, REC state, database status
   - per region: read/write probe result and latency, availability
   - replication: **lag and sync status as reported by Redis Enterprise** (REST `crdt_sources[].lag/status`);
     if a value is not provided by REC, it is not shown
   - ops/s and server-side latency if the REC stats API gives them cheaply
   - a "data converges" check (counter written on A read back on B) if it stays simple
5. **Refresh policy.** Sequential collectors: ask for the next status only when the previous answer
   arrived (no overlapping `kubectl`/REST calls), at most 1 command/second for the fast ones.
   Continuous refresh while a chaos run is active, **every 10 s otherwise**. Every value shows its age;
   an unreachable cluster is marked as such after a timeout instead of freezing the page.
6. **Testable tonight.** Smallest slice below.

## Non-goals

- No buttons that start chaos from the browser, no database, no user accounts.
- No exposure beyond `localhost` (bind 127.0.0.1; event endpoint accepts localhost only).
- No history/time-series charts. No React/Vite build: Flask + Jinja + vanilla JS (live updates via SSE or polling).
- Not a monitoring product: only what helps narrate a chaos scenario.

## Constraints

- Runs on the **host** (needs kubectl contexts and cluster credentials); the VM has none.
  UI work in the VM therefore needs a **fixture/mock data mode** to develop and screenshot offline (Playwright).
- Flask `debug=True` must go (Werkzeug debugger = remote code execution; CLAUDE.md gotcha 8).
- Data sources must not disturb the experiment: avoid `kubectl exec` into the REC pods being killed.
  Preferred: REC **REST API through the public ingress** (`api.<rec>.<zone>`, cluster credentials) for
  nodes/databases/lag/stats, plus cheap `kubectl get` for pods/nodes. To verify: which stats fields exist.
- Python deps pinned (`flask/requirements.txt`); the DB password is read from the K8s secret, never logged.
- Cross-platform shell: scripts are bash, `chmod 700`.

## Risks and open questions

1. **Slow or hanging commands** during a region outage (the down cluster never answers). Needs per-source
   collectors with hard timeouts so the surviving region keeps updating.
2. **REST API availability during chaos**: the ingress route may disappear with the pods; "unreachable"
   must be a first-class displayed state, not an error page.
3. **Observer effect**: polling must not add load or fail the scenario it is observing.
4. **Scope vs "tonight"**: the full v2 will not fit. See slice order.
5. Open: exact REC REST fields for ops/s and latency; whether lag is exposed per replica link
   (seen: `crdt_sources[].lag` = 0 and `status` = in-sync); event transport (HTTP POST + SSE chosen unless a reason appears).

## First slice (order of delivery, each independently testable)

1. **Silent, safe launcher**: rename + stop script, logs to `debug/`, `debug=False`, bind 127.0.0.1, PID file.
2. **Event channel + scenario banner**: `POST /api/chaos/event` (localhost only); `chaos.sh` posts phase
   start/end and results; page shows scenario, expected behaviour, timer, timeline with PASS/FAIL.
3. **Redis skin** at 1800x1169 (+ mock-data mode so it can be built and screenshotted in the VM).
4. **Indicators** v1 from the existing sources (nodes, pods, DB status, probe latency, REC lag/status).
5. Later: ops/s, convergence check, REST-through-ingress collector replacing `kubectl exec`.

## Next steps

`/skills-review` (activate `redis-brand-ui` / `redis-product-ui` for this project if not yet active),
then `/spec` on slice 1-2 (update `docs/specs/demo-console.md`), then `/plan-feature`.
