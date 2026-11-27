# Spec — Cloud provider abstraction

**Owner:** `config.sh`, `config.example.sh`, the `case $CLOUD_PROVIDER` blocks in
`scripts/01-create-cluster.sh`, `scripts/delete-all-resources.sh`, root `check-tags.sh`.
**Status (2026-11-27):** implemented for steps 01–05, teardown and the deploy entry points; chaos has its own per-provider functions (the `providers/*/chaos-provider.sh` files stay unused).

## Current state (2026-11-27)

All `providers/*/variables.tf` have no defaults and every value reaches OpenTofu as `TF_VAR_*` from `config.sh` (`scripts/verify-config.sh all`). Steps 02–05 contain no direct cloud call outside `case $CLOUD_PROVIDER` arms. GCP is exercised for real; AWS and Azure only validate.

## Purpose

Let one codebase deploy the same Redis Enterprise Active-Active demo on Azure, AWS or GCP by
changing a single value, `CLOUD_PROVIDER`.

## Inputs

| Input | Source | Values | Required |
|---|---|---|---|
| `CLOUD_PROVIDER` | `config.sh` | `azure` \| `aws` \| `gcp` | yes |
| `AZURE_CLUSTER_RESOURCE_GROUP`, `AZURE_DNS_RESOURCE_GROUP`, `AZURE_REGION1/2`, `AZURE_INSTANCE_TYPE` | `config.sh` | strings | when azure |
| `AWS_CLUSTER_RESOURCE_GROUP`, `AWS_REGION1/2`, `AWS_INSTANCE_TYPE` | `config.sh` | strings | when aws |
| `GCP_PROJECT_ID`, `GCP_REGION1/2`, `GCP_INSTANCE_TYPE` | `config.sh` | strings | when gcp |
| `DNS_ZONE`, `AA_DB_NAME`, `NS`, `CLUSTER_PREFIX`, `owner`, `skip_deletion` | `config.sh` | strings | yes |

## Outputs

Generic shell variables consumed by every downstream script:

`CLUSTER_RESOURCE_GROUP`, `DNS_RESOURCE_GROUP`, `REGION1`, `REGION2`, `INSTANCE_TYPE`,
`CLUSTER1=${CLUSTER_PREFIX}-${REGION1}`, `CLUSTER2=${CLUSTER_PREFIX}-${REGION2}`, `CLUSTER3` (empty),
plus a 6-line confirmation banner on stdout.

## Behaviour

1. `config.sh` is sourced (`source ../config.sh`) — it is not executed.
2. The `case` maps the selected cloud's `<CLOUD>_*` variables onto the generic names.
3. An unrecognised `CLOUD_PROVIDER` prints `❌ ERROR: Invalid CLOUD_PROVIDER: …` and calls
   `exit 1`.
4. Provider-aware scripts `cd ../providers/$CLOUD_PROVIDER` and/or branch on the same `case`.

## Edge cases

| Case | Current behaviour | Correct behaviour |
|---|---|---|
| Invalid `CLOUD_PROVIDER` | `exit 1` from a **sourced** file → kills the *calling* shell, so an interactive `source config.sh` closes the terminal | `return 1` when sourced |
| `CLOUD_PROVIDER=aws` or `gcp` | `DNS_RESOURCE_GROUP` is left **unset** (only the azure arm sets it) | set it, or make DNS scope provider-specific |
| Region contains characters illegal in a K8s name | `CLUSTER1` silently becomes an invalid resource name | validate against `^[a-z]([a-z0-9-]*[a-z0-9])?$` |
| `owner` not `firstname_lastname` | AWS/GCP fail at `tofu` validation; **Azure accepts it** | validate centrally in `config.sh` |
| `config.sh` missing | every script dies with `No such file or directory` | detect and print "copy config.example.sh" |
| Regions/instance types changed | **silently ignored by Terraform** (never exported as `TF_VAR_*`) | must be exported |
| `CLUSTER3` set | ignored by steps 01-05; **read** by `launch_test.sh` and `redis_connectivity_benchmark.py`, which would target a non-existent host | out of scope; remove or implement end-to-end |

## Known defects

- **D1 — `TF_VAR_region1`/`region2`/instance type are never exported.** Terraform uses
  `providers/*/variables.tf` defaults. Azure coincidentally matches; AWS/GCP do not
  (`GCP_REGION2` `europe-west1` vs `us-west1`; `AWS_INSTANCE_TYPE` `m5.2xlarge` vs `t3.xlarge`;
  `GCP_INSTANCE_TYPE` `n1-standard-8` vs `e2-standard-4`). **Editing `config.sh` regions does
  nothing.**
- **D2 — `TF_VAR_project_id` is never exported for GCP**, and `project_id` has no default →
  `tofu apply` fails outright.
- **D3 — `TF_VAR_aws_account_id` is exported but declared nowhere** → silently ignored.
- **D4 — `INSTANCE_TYPE` has no consumer at all.** The three provider modules use differently
  named variables (`instance_type`, `node_instance_type`, `node_machine_type`).
- **D5 — Only step 01, teardown and tag-checking are provider-aware.** Steps 02–05 and
  `chaos.sh` ignore `CLOUD_PROVIDER` entirely.
- **D6 — `config.example.sh` is ahead of `config.sh`**: it defines `CLUSTER_RESOURCE_GROUP`,
  `DNS_RESOURCE_GROUP`, `GCP_CLUSTER_RESOURCE_GROUP`, `NODE_COUNT`, which `config.sh` lacks.
- **D7 — `config.sh` is committed** with personal values; it should be gitignored.
- **D8 — no shebang** in `config.sh`/`config.example.sh` (shellcheck SC2148); 8 and 17
  shellcheck warnings respectively.

## Acceptance criteria

- [ ] `CLOUD_PROVIDER` ∈ {azure, aws, gcp} selects the right provider directory and CLI paths.
- [ ] Every value in `config.sh` that Terraform needs is exported as `TF_VAR_*`; changing a
      region in `config.sh` changes the region in `tofu plan` output, on all three clouds.
- [ ] No provider module relies on a default that contradicts `config.sh`.
- [ ] An invalid `CLOUD_PROVIDER` fails cleanly without killing an interactive shell.
- [ ] `owner`/`skip_deletion` are validated once, centrally, with identical rules per cloud.
- [ ] `config.sh` is gitignored; `config.example.sh` is its complete superset.
- [ ] `shellcheck -S warning config.sh config.example.sh` is clean.
- [ ] Steps 02–05 and `chaos.sh` are provider-aware (see the other specs).
