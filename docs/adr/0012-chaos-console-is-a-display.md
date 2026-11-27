# ADR 0012 — The chaos console is a read-only display, driven by the script

- **Status:** Accepted 2026-11-26
- **Evidence:** `flask/`, `common/chaos-notify.sh`, `docs/specs/chaos-webui.md`, `docs/product/brief.md`.

## Context

A presenter shares one screen and runs chaos scenarios step by step. The console must tell the audience
what is being simulated, what to expect and how long recovery took, without becoming a second place where
things can be broken or a service that can be attacked (the old version ran Flask with `debug=True`).

## Decision

- **Display only:** no button starts or stops chaos; `chaos.sh` is the only actor and *tells* the console what it does (`run_start`, `phase_start`, `inject`, `step`, `phase_end`, `run_end`).
- **Best effort:** the console being down or slow never fails or delays a run (2 s timeout, one warning line).
- **Local only:** binds `127.0.0.1`, `debug=False`; the event endpoint accepts loopback only, 4 KB bodies, validated and clipped; page text is rendered with `textContent` only; the REST data (`/aadb/<r>`) is whitelisted so credentials and certificates never leave the server.
- **Bounded:** every data route answers within 4 s even if a region is dead; the page keeps the last known value, dimmed, instead of blanking.
- State is in memory (last run only); no database, no accounts.

## Consequences

The console cannot mislead by acting; its truth is whatever `chaos.sh` reports plus what it can read from the clusters. It cannot be used remotely (use screen sharing). Adding a control would need a new ADR and an authentication story.
