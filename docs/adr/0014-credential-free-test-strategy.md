# ADR 0014 — Test strategy: credential-free tests, host-side validation

- **Status:** Accepted 2026-11-27 (answers the "testing strategy" question left open in `README.md` of this folder)
- **Evidence:** `tests/run.sh`, `tests/shell/`, `flask/tests/`, `flask/tests/js/`.

## Decision

- Everything that can be proven **without cloud credentials** is tested automatically by `./tests/run.sh` (VM or host): `pytest` for the Flask console, `node --test` for the page logic, bash tests that run `chaos.sh` and the launchers against **stubbed `kubectl`, `gcloud`, `curl`** (`tests/shell/stubs/`, state machine included, e.g. a pool resized to 0), `shellcheck -S warning` on the tested scripts, `ruff`, and a check that user-run scripts keep their executable bit.
- Anything that touches a real cloud is validated **on the host, by running it**, and the result is read from the logs in `debug/` (ADR 0013). Stubs encode what we learned from real runs, never what we hope.
- New behaviour starts with a failing test (TDD); a bug found on a real cluster gets a regression test with a stub variant (`STUB_REGION_NOEFFECT`, `STUB_GCLOUD_UNAUTH`, …).

## Consequences

Stubs can drift from the real tools; the real runs remain the final judge. There is **no CI yet** (`docs/TODO.md` D), so the suite runs when someone runs it.
