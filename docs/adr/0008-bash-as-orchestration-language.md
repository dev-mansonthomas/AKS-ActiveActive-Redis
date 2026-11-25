# ADR 0008 — Bash as the orchestration language

- **Status:** Accepted (at its practical limit)
- **Date:** origin of the project
- **Evidence:** 53 tracked `*.sh` files; Python used only for the Flask console and load/latency
  tooling; no Makefile, no task runner, no CI.

## Context

The work is almost entirely sequencing external CLIs — `tofu`, `kubectl`, `helm`, `az`/`aws`/
`gcloud`, `jq`, `curl`. The audience is Solution Architects who need to read, tweak and explain
each step live in front of a customer.

## Decision

Plain Bash (`#!/usr/bin/env bash`), numbered sequentially (`01-…` → `05-…`) so the deployment
order is self-documenting, with `create-all.sh` chaining them and timing each step.

## Consequences

**Positive** — no runtime to install; every line maps to a command an SA can run by hand and
narrate; numbered files make the pipeline obvious; `wait_until`-style retry helpers are easy to
follow.

**Negative — the design has now outgrown it**
- **No tests and no CI.** 53 scripts, zero automated verification. Every regression is found at
  demo time. This is the root cause of the state described in `../migration-status.md`: three
  "COMPLETE" phases shipped without anyone executing them.
- **Relative-path fragility.** Each script assumes a CWD, and after the Phase 1 move those
  assumptions became mutually contradictory (`source ../config.sh` vs `templates/`, `yaml/`),
  making steps 02–05 unrunnable from **any** directory. A language with a module system would
  not have this failure mode. Mitigation: anchor with `cd "$(dirname "$0")/.."`.
- **`set -e` is applied inconsistently** — step 02 has it, step 03 does not, so the same
  `cat config.sh` bug is fatal in one and merely noisy in the other.
- **82 shellcheck warnings** (36 × SC2155 masked return values, 26 × SC2034 unused, 9 × SC2154
  possibly-unset, 5 × SC2148 missing shebang, 4 × SC2164, 2 × SC2207).
- **Duplication instead of reuse.** Eight root scripts are stale copies of their `scripts/`
  counterparts; `get_config_var` is reimplemented twice in Python; `check-tags.sh` exists twice.
- No structured error handling, so partial failures leave undefined state.

## Follow-up

Keep Bash — rewriting is not worth it for a demo rig — but add the cheap guardrails:
`shellcheck` in a pre-commit hook and CI, `set -euo pipefail` uniformly, path anchoring via
`$(dirname "$0")`, and delete the duplicated root scripts. See `../TODO.md`.
