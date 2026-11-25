# Spec — Load generation & latency measurement

**Owner:** `redis-enterprise-testing/` — `launch_test.sh`, `redis_connectivity_benchmark.py`,
`get_key.py`, `incr_key.py`, `continuous_load/` (Docker + K8s), `continuous_load_v2/memtier_benchmark.yml`,
`standalone-db/` (00–06).
**Status:** works; cloud-agnostic by construction (it only ever talks to FQDNs from `config.sh`).

## Purpose

Generate write pressure and measure cross-region behaviour so the Active-Active claim is
observable: writes continue during an outage, and concurrent regional `INCR`s converge instead
of overwriting.

## Inputs

`AA_DB_NAME`, `CLUSTER1`, `CLUSTER2`, `CLUSTER3` (optional), `DNS_ZONE` from `config.sh`
(sourced as `. ../config.sh` → **run from `redis-enterprise-testing/`**); the DB password from
the K8s secret; Python deps from `requirements.txt` via `./install-python-reqs-for-test.sh`.

Host derivation: `HOST<n> = ${AA_DB_NAME}-db.${CLUSTER<n>}.${DNS_ZONE}`, `PORT=443` (TLS).

`launch_test.sh` flags: `reset` (clear the counter first), `pipe` (use pipelining).

## Outputs

- `launch_test.sh` — `INCR counter` 1000× against region 1 and 1000× against region 2, then the
  converged value. With Active-Active CRDT counters the expected result is **2000**: proof that
  concurrent multi-master increments sum rather than clobber.
- `redis_connectivity_benchmark.py` — per-region write/read latency samples (µs) using
  `datetime.now()` deltas.
- `continuous_load/load_generator.py` — continuous random-key writes (`loadtest:` prefix,
  8-char random suffix, 10 ms delay), driven by `REDIS_HOST`/`REDIS_PORT` env vars; built by
  `build-docker.sh` and deployed via `loadgen.yaml`.
- `standalone-db/00..06` — a separate non-AA demo: create DB, enable HA, increase RAM, increase
  shard count, upgrade version, delete — used to show online scaling without interruption.

## Edge cases

| Case | Behaviour |
|---|---|
| DNS not resolving | connection error from `redis-py` |
| `CLUSTER3` empty | `launch_test.sh` guards with `[ -n "$CLUSTER3" ]`; the benchmark reads it unguarded |
| Run from the repo root | `. ../config.sh` fails — must run from `redis-enterprise-testing/` |
| TLS on 443 | connections must use `rediss://`; `load_generator.py` defaults to plain `localhost:6379` for in-cluster use |
| Outage mid-run | this is the point; errors should be retried, not fatal |

## Known defects

- **D1 — `load_generator.py` exits on the first connection failure** (`sys.exit(1)`), so a
  chaos-induced blip kills the generator instead of demonstrating recovery. It should retry
  with backoff — this is the tool meant to *prove* continuity.
- **D2 — `launch_test.sh` asserts nothing.** It prints the counter; a human decides whether
  2000 is correct. Should exit non-zero on mismatch.
- **D3 — `ruff` reports 21 findings**, including `DTZ005` (`datetime.now()` without `tz`) in the
  benchmark — naive timestamps; 9 are auto-fixable.
- **D4 — the benchmark measures `.microseconds`** of a `timedelta`, which **wraps at 1 s** and
  silently under-reports anything slower. Use `.total_seconds()`.
- **D5 — `README.md` references `cli-cluster{1,2}.sh`**; the files are `aadb-cli-cluster{1,2}.sh`.
- **D6 — the Docker image is hardcoded** to `thomasmanson458/redis-loadgen:latest` in
  `build-docker.sh` and `loadgen.yaml`; `:latest` is unpinned. Also `build-docker.sh` has no
  shebang (SC2148).
- **D7 — ~~Azure-named script~~** ✅ fixed 2026-09-07: renamed to
  `check-redis-enterprise.sh` (it never had a cloud-specific call) and ported to
  `common/lib.sh`; writes to `debug/re-state-<ts>/`, no longer wipes `logs/`.
- **D8 — an untracked `.venv/` exists** inside `redis-enterprise-testing/` (correctly gitignored,
  but it means a stale interpreter can shadow a fresh install).

## Acceptance criteria

- [ ] `./launch_test.sh reset` **asserts** the converged counter equals the sum of both regions'
      increments and exits non-zero otherwise.
- [ ] `load_generator.py` survives a region outage: retry with backoff, report an error/success
      count on exit rather than dying.
- [ ] Latency is measured with `total_seconds()`, timezone-aware.
- [ ] `ruff check` clean.
- [ ] The load-gen image is pinned to a digest or version tag.
- [ ] Every script documents its required CWD, or is CWD-independent.
