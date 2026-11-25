# ADR 0005 — A single shell file (`config.sh`) as the only configuration source

- **Status:** Accepted, **partially honoured**
- **Date:** 2025 (commit `0ec2a6c`, *"flask/app.py: use config.sh as config source"*; `c7cf4b3`
  added documentation to `config.sh`)
- **Evidence:** every script does `source ../config.sh`; `flask/app.py` and `flask/k8s.py` parse
  it with `get_config_var()`; `README.md`'s Todo says *"Improve the use of variables so that it
  relies on config.sh only"*.

## Context

Values (regions, cluster names, DNS zone, namespace, tags) are needed by Bash, OpenTofu and
Python. Options: `.env` + a loader per language; `.tfvars` + duplication in shell; a YAML/JSON
file plus parsers; or one shell file that Bash sources natively.

## Decision

One **`config.sh`**, sourced by shell and hand-parsed by Python. `config.example.sh` is the
template. Terraform receives values only as exported `TF_VAR_*` — there are deliberately **no
`.tfvars` files**, so a value cannot be set in two places.

## Consequences

**Positive** — zero-dependency for the dominant language; supports derived values
(`CLUSTER1=${CLUSTER_PREFIX}-${REGION1}`) and the `case $CLOUD_PROVIDER` normalisation, which a
static format could not; self-documenting via comments.

**Negative**
- **The "single source of truth" is not actually authoritative.** No script exports
  `TF_VAR_region1`/`region2` or any instance type, so Terraform silently uses the defaults in
  `providers/*/variables.tf`. Editing regions in `config.sh` does nothing; Azure only appears
  to work because the defaults coincide. `INSTANCE_TYPE` has **no consumer at all**.
  See `../specs/cloud-provider-abstraction.md` D1/D4.
- Sourcing means **arbitrary code execution** — `config.sh` calls `echo` and `exit 1`. The
  `exit 1` on an invalid provider kills the *calling* shell when sourced interactively; it
  should be `return 1`.
- Python duplicates a hand-rolled parser in two files rather than importing one helper.
- `config.sh` is **committed** with personal values (`ThomasManson-temp-AKS`,
  `demo.paquerette.com`, `thomas_manson`). It should be gitignored in favour of
  `config.example.sh` — which is already **ahead** of it (`CLUSTER_RESOURCE_GROUP`,
  `DNS_RESOURCE_GROUP`, `GCP_CLUSTER_RESOURCE_GROUP`, `NODE_COUNT`).
- No shebang → shellcheck SC2148; 8 warnings in `config.sh`, 17 in `config.example.sh`.
