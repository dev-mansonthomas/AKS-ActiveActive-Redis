# Spec — Flask demo console

**Owner:** `flask/app.py`, `flask/k8s.py`, `flask/templates/index.html`,
`scripts/launch-flask-console.sh` (+ its identical root duplicate).
**Status:** works locally. Screenshot: `images/flask_app.png`.

## Purpose

A small web UI that makes Active-Active behaviour visible during a demo: write/read per region,
show cluster health, and keep working while one region is being broken by `chaos.sh`.

## Inputs

`config.sh`, parsed by `get_config_var(name, config_path="../config.sh")` — **so the app must run
from `flask/`**. Values used: `AA_DB_NAME`, `CLUSTER1`/`CLUSTER2`/`CLUSTER3`, `DNS_ZONE`, `NS`.
The Redis password is read from the `rec-<cluster>` K8s secret and base64-decoded. Requires a
working kubeconfig.

## Outputs / routes

| Route | Purpose |
|---|---|
| `/` | index page (`templates/index.html`) |
| `/redis/<region>` | write/read against that region's AA DB endpoint |
| `/redisha` | HA view across regions |
| `/cluster/<region>` | cluster/REC status for that region |

Redis endpoint: `host=f"{aaDbName}-db.{region}.{dns_suffix}"`.

## Behaviour

`connect_to_redis(region)` builds the per-region FQDN and connects; `get_cluster(region)` pulls
REC state and credentials via the `kubernetes` client and `subprocess` (`k8s.py`);
`launch-flask-console.sh` starts the server and opens a browser.

## Edge cases

| Case | Behaviour |
|---|---|
| Region unreachable (chaos in progress) | the route should degrade gracefully — **(inferred — verify)**; this is the console's whole purpose and needs an explicit test |
| Unknown `<region>` | not validated — user input flows into the hostname |
| kubeconfig missing/expired | `kubernetes` client raises; surfaced as a 500 |
| Run from the repo root | `../config.sh` not found → startup failure |

## Known defects

- **D1 — 🔴 `app.run(debug=True)`.** The Werkzeug debugger allows arbitrary code execution on
  any request that raises. Safe only bound to localhost; **never expose this**. Should be
  `debug=os.environ.get("FLASK_DEBUG") == "1"`.
- **D2 — `<region>` is unvalidated** and is interpolated into the Redis hostname. Restrict it to
  `{CLUSTER1, CLUSTER2, CLUSTER3}` from `config.sh`.
- **D3 — `config.sh` is parsed by hand** rather than sourced, in two places
  (`app.py` and `k8s.py` each define their own `get_config_var`) — duplicated logic that will
  drift.
- **D4 — no `flask/requirements.txt`.** Dependencies (`flask`, `redis`, `kubernetes`) are
  undeclared; only `redis-enterprise-testing/requirements.txt` exists.
- **D5 — `subprocess` use in `k8s.py`** alongside the official client; prefer the client alone.
- **D6 — `launch-flask-console.sh` is duplicated** verbatim at the repo root and in `scripts/`.
- **D7 — no error handling shown on the routes**; a dead region likely 500s instead of rendering
  "region down", which is exactly what the demo needs to show.

## Acceptance criteria

- [ ] `debug` is off by default and opt-in via an env var.
- [ ] `<region>` is validated against the configured cluster names; unknown → 404.
- [ ] A region being down renders a clear "unavailable" state **and the other region still
      serves reads and writes** — the console must stay usable throughout `chaos.sh`.
- [ ] `flask/requirements.txt` exists and pins versions.
- [ ] `get_config_var` lives in one module, imported by both files.
- [ ] Startup works from a documented CWD, or is CWD-independent.
- [ ] `ruff check flask/` clean.
