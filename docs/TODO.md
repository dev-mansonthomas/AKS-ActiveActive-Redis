# TODO

Compiled **2026-09-04** from: the actual code, `shellcheck`/`ruff`/`tofu validate` output, the
root-level AI-generated status docs (`MULTI_CLOUD_COMPLETE.md`, `PHASE*_COMPLETE.md`,
`VALIDATION_CHECKLIST.md`, `EFFORT_ESTIMATION.md`), `README.md`'s own Todo list, and git history.

There are **no `TODO`/`FIXME`/`HACK` comments in the code** — every item below was derived from
observed behaviour or a doc/code conflict.

**Severity:** 🔴 blocker · 🟠 high · 🟡 medium · 🔵 low/hygiene

---

## A. Multi-cloud completion — the headline gap

`MULTI_CLOUD_COMPLETE.md` claims all three phases are complete and "production-ready".
`VALIDATION_CHECKLIST.md` has **183 unchecked boxes and 0 checked**. Nothing was executed.

| | Item | Sev | Notes |
|---|---|---|---|
| A1 | ✅ **DONE** — step 02 rewritten provider-agnostic: **0 direct cloud calls**. Credentials via `re_kube_credentials` → `providers/$CLOUD_PROVIDER/get-credentials.sh`; DNS via `re_dns_lib` + `re_dns_upsert` → `common/dns-$CLOUD_PROVIDER.sh`. Also added: `helm upgrade --install` (idempotent), pinned chart/operator versions, REC-Running wait, and a post-deploy DNS resolution check. | ✅ |
| A2 | ✅ **DONE** — steps 02–05 now source `common/lib.sh`, use `$REPO_ROOT`/`$TEMPLATES_DIR`/`$YAML_DIR`, and the `cat config.sh` lines are gone. Verified by running each script from the repo root, from `scripts/`, and from `/tmp` — identical startup. Also rewrote `providers/*/get-credentials.sh` (they hardcoded the `redis-` prefix and sourced `../../config.sh` relatively). | ✅ |
| A3 | ✅ **DONE** — solved structurally, not by patching two lines. `common/lib.sh::re_export_tf_vars` exports **every** `TF_VAR_*` from `config.sh` for all three clouds; used by step 01 and teardown. `scripts/verify-config.sh` proves it credential-free. | ✅ |
| A4 | ✅ **DONE** — `required_providers` pinned at `azurerm ~> 5.4` and `node_provisioning_profile { mode = "Manual" }` added to both clusters. `tofu validate` passes. | ✅ | Azure is now **last** priority (no access). Note azurerm **5.4.0 is the latest release**, so "update to latest" means fixing the code *forward*, **not** pinning back to `~> 4.26`. See §G. |
| A5 | ✅ **DONE** — all `variables.tf` now have **0 defaults** (azure 12, aws 12, gcp 19 variables) and every value comes from `config.sh`. Also found and fixed: AWS declared 5 variables it never used (`eks_version`, `node_instance_type`, `node_desired/min/max_size`) while hardcoding 1.29 / t3.xlarge. | ✅ |
| A6 | Make `scripts/chaos.sh` dispatch to `providers/*/chaos-provider.sh`. | 🟠 | 9 hardcoded `az` calls, zero `CLOUD_PROVIDER` refs; all three `chaos-provider.sh` are dead code. |
| A7 | ✅ **DONE** — teardown now sources `common/dns-aws.sh` / `common/dns-gcp.sh` and calls `delete_dns_record` per cluster. Those files were dead code since Phase 2/3. | ✅ |
| A8 | **Partially done.** `re_ingress_address` now returns `.ip` *or* `.hostname`, so step 02's wait works on EKS. **Still missing:** `common/dns-aws.sh` only creates A records, so a hostname needs CNAME/alias support — `re_dns_upsert` now **fails loudly** on AWS instead of writing a broken record. | 🟠 | Milestone 3 (AWS). |
| A9 | Remove `TF_VAR_aws_account_id` (declared by no AWS variable) or declare it. | 🔵 | Silently ignored. |
| A10 | **Actually run and tick `VALIDATION_CHECKLIST.md`** — one full create → chaos → destroy cycle per cloud. | 🔴 | The only way any completion claim becomes true. |
| A11 | Extract `common/dns-azure.sh` so all three clouds share one DNS interface. | 🟡 | Azure logic is inline in step 02. |
| A12 | **Cross-cloud Active-Active** (AKS ↔ EKS) — **nice-to-have, not a goal.** Two regions within one cloud is the demo. | 🔵 | Would need per-cluster provider selection; one `CLOUD_PROVIDER` per run makes it impossible today. Deferred, see ADR 0002 / 0010. |

## B. Security

| | Item | Sev | Notes |
|---|---|---|---|
| B1 | **Harden — do not close — public reachability.** The GCP firewall `redis-allow-redis-ports` opens TCP **8001, 8443, 9443, 10000-19999** (the Redis Enterprise **database endpoint** range) to `0.0.0.0/0`. Reaching the DB / management UI / status console **from anywhere is a stated product requirement**, so the fix is *authenticated + encrypted* exposure, not a closed port. | 🟠 | Do: enforce TLS on the DB endpoint, a strong generated DB password (not just the default admin), Redis ACLs, and drop `8001`/`9443` (internal operator/UI ports) from the public rule. Keep 443 + the DB port range reachable. **Do not** scope to a fixed client IP — that breaks the demo. |
| B2 | **Turn off `app.run(debug=True)`** in `flask/app.py`. | 🟠 | Werkzeug debugger = RCE on any exception. Gate behind `FLASK_DEBUG`. |
| B3 | Validate `<region>` in the Flask routes before interpolating it into a hostname. | 🟠 | Unvalidated user input; restrict to configured cluster names. |
| B4 | **REVERSED 2026-09-07 on the owner's call.** Passwords are now printed **by default** by step 05 (`--hide-secrets` opts out). This is a disposable demo rig whose purpose is to hand an operator something to paste into a UI — masking meant re-running with a flag every single time. Step 03 still passes the password via `curl -u` (visible in the process table); accepted for the same reason. Consistent with ADR 0010. | ✅ |
| B5 | ✅ **DONE** — pinned to `v8.2.0-13` (overridable via `OPERATOR_VERSION`). | ✅ |
| B6 | Gitignore `config.sh`; keep only `config.example.sh` tracked. | 🟡 | Committed with personal values (`ThomasManson-temp-AKS`, `demo.paquerette.com`). No secrets, but wrong pattern. |
| B7 | ~~Private clusters~~ — **rejected**: a private GKE/EKS control plane would break "1 command from anywhere". Instead keep public API-server endpoints and rely on cloud IAM + short-lived demo lifetime. | 🔵 | Deliberate trade-off, recorded in ADR 0010. Revisit only if a customer demands it. |
| B8 | Replace `curl -k` in step 03 with proper CA trust. | 🔵 | Self-signed operator certs; acceptable for a demo. |
| B9 | **Evaluate GCP resource-manager tags** for `owner`/`skip_deletion` on network resources. | 🟡 | Labels are impossible on `google_compute_{network,subnetwork,firewall}` and `google_container_node_pool` (verified against provider 8.1). Attribution there rests entirely on `CLUSTER_PREFIX` naming — a label-keyed reaper is blind to them. GCP *tags* (distinct from labels) may cover networks. See ADR 0006. |

## C. Correctness & robustness

| | Item | Sev | Notes |
|---|---|---|---|
| C1 | ✅ **DONE** — `re_yaml_dir_init [--clean]` in `common/lib.sh`; `rm -f`, `mkdir -p`. |  ✅ |
| C2 | ✅ **DONE** — `re_ns_ensure <context> <ns>` uses `--dry-run=client -o yaml \| kubectl apply -f -`. | ✅ |
| C3 | ✅ **DONE** — steps 04 and 05 use `$NS`; no literal `rec` remains. | ✅ |
| C4 | ✅ **DONE** — step 03 uses `kubectl -o jsonpath` directly instead of `jq` (no quoting ambiguity at all). | ✅ |
| C5 | **Mostly done** — every pipeline script now uses `set -uo pipefail` with explicit `\|\| re_die` at each failure point (deliberately not `-e`, so teardown and diagnostics can continue past a single failure). Remaining: `chaos.sh` and the `redis-enterprise-testing/` scripts. | 🔵 |
| C6 | ✅ **DONE** — step 04 now polls `reaadb .status.status` until `active` (10 min cap); step 05 warns instead of printing garbage when a host is missing. | ✅ |
| C7 | ✅ **DONE** — `return 1 2>/dev/null \|\| exit 1`. | ✅ |
| C8 | Retry with backoff in `continuous_load/load_generator.py` instead of `sys.exit(1)`. | 🟠 | The tool meant to **prove** continuity dies at the first chaos-induced blip. |
| C9 | Use `total_seconds()` in `redis_connectivity_benchmark.py`. | 🟡 | `.microseconds` **wraps at 1 s**, silently under-reporting slow calls. |
| C10 | ✅ **DONE** — ingress address wait raised to 36 × 10 s (6 min), REC-Running to 60 × 10 s (10 min), secrets/CRD to 24 × 5 s. | ✅ |
| C11 | Replace `az vmss list -o table \| grep` with `--query` in `chaos.sh`. | 🟡 | Brittle table parsing; always targets instance `[0]`. |
| C12 | **Partially done** — step 02 ends with a `dig` check on `api.<cluster>.<zone>` and warns if unresolved. A hard blocking wait is still not implemented. | 🔵 |
| C13 | Use delimited template tokens (`{{CLUSTER}}`). | 🔵 | Bare `s/CLUSTER/…/g` is a latent collision trap (ADR 0003). |
| C14 | Validate derived cluster names against `^[a-z]([a-z0-9-]*[a-z0-9])?$`. | 🔵 | A region with illegal characters yields an invalid resource name. |
| C15 | Guard `CLUSTER3` in `redis_connectivity_benchmark.py` as `launch_test.sh` does. | 🔵 | Reads it unguarded; would target a non-existent host. |

## D. Testing & CI — currently zero

| | Item | Sev | Notes |
|---|---|---|---|
| D1 | **Add CI** running `shellcheck`, `ruff`, `tofu fmt -check`, `tofu validate`. | 🟠 | 53 shell scripts, no `.github/`, no tests. This is the root cause of section A: three "COMPLETE" phases shipped unexecuted. |
| D2 | Add a `tofu validate` pre-commit hook. | 🟠 | Would have caught A4 (the Azure regression) immediately. |
| D3 | Make `launch_test.sh` **assert** the converged counter (expect 2000) and exit non-zero on mismatch. | 🟠 | **Next after this milestone.** Today it prints a number and a human decides. This is the project's core claim — it should be machine-checked. |
| D4 | Add an automated assertion to `chaos.sh`: zero writes lost across an outage. | 🟠 | `README.md`'s own Todo: *"chaos.sh: automate every action for HA testing"*. |
| D5 | A non-interactive `--yes` mode for `chaos.sh`. | 🟡 | `read -rp` blocks forever unattended. |
| D6 | Smoke-test the Flask console (a region down must render "unavailable", not 500). | 🟡 | That behaviour **is** the demo. |

## E. Repository hygiene

| | Item | Sev | Notes |
|---|---|---|---|
| E1 | **Delete the 8 legacy root duplicates** (`01`–`05`, `chaos.sh`, `launch-flask-console.sh`, `recreate.sh`) + root `main.tf`/`variables.tf`/`output.tf` + `scripts/check-tags.sh`; add root wrappers instead. | 🟠 | **Only after A4** — the legacy root Terraform is currently the only Azure config that validates. See ADR 0009. |
| E2 | **Consolidate the 11 root `*.md` files.** `MULTI_CLOUD_COMPLETE.md`, `PHASE{1,2,3}_COMPLETE.md`, `IMPLEMENTATION_SUMMARY.md`, `MULTI_CLOUD_SUPPORT_PLAN.md`, `EFFORT_ESTIMATION.md`, `README_MULTI_CLOUD.md`, `QUICK_START_GUIDE.md`, `GIT_WORKFLOW.md` (~3,700 lines) are superseded by `docs/`. | 🟠 | They assert a completion that does not exist — actively misleading. Archive under `docs/archive/` or delete; keep `VALIDATION_CHECKLIST.md` (still useful) and `README.md`. |
| E3 | Fix `README.md`: it documents the **legacy** path and references `cli-cluster{1,2}.sh`, which do not exist (they are `aadb-cli-cluster{1,2}.sh`). | 🟠 | Documented instructions disagree with the intended architecture. |
| E4 | Sync `config.sh` with `config.example.sh`. | 🟡 | The example is **ahead**: `CLUSTER_RESOURCE_GROUP`, `DNS_RESOURCE_GROUP`, `GCP_CLUSTER_RESOURCE_GROUP`, `NODE_COUNT` are missing from `config.sh`. |
| E5 | Set `DNS_RESOURCE_GROUP` in the `aws`/`gcp` arms of `config.sh`, or make DNS scope provider-specific. | 🟡 | Unset for non-Azure; teardown passes an empty `-g`. |
| E6 | Clear the 82 `shellcheck` warnings. | 🟡 | 36 × SC2155, 26 × SC2034, 9 × SC2154, 5 × SC2148, 4 × SC2164, 2 × SC2207. Worst: `config.example.sh` (17), `common/dns-aws.sh` (11), `config.sh` (8), `common/dns-gcp.sh` (8). |
| E7 | Clear the 21 `ruff` findings (9 auto-fixable). | 🔵 | Incl. `DTZ005` naive `datetime.now()`. |
| E8 | Add shebangs to `config.sh`, `config.example.sh`, `continuous_load/{build-docker,deploy_container_on_k8s,remove_pod}.sh`. | 🔵 | SC2148 — the only `shellcheck -S error` findings. |
| E9 | Add `flask/requirements.txt`. | 🟡 | `flask`, `redis`, `kubernetes` are undeclared. |
| E10 | De-duplicate `get_config_var` (defined in both `flask/app.py` and `flask/k8s.py`). | 🔵 | Will drift. |
| E11 | Pin the load-gen image; drop `:latest`. | 🔵 | `thomasmanson458/redis-loadgen:latest`. |
| E12 | ~~Remove tracked `.DS_Store` files~~ — **not an issue**: present on disk but correctly gitignored and untracked. | 🔵 | Verified: `git ls-files` matches none. |
| E13 | ✅ **DONE** — renamed to `check-redis-enterprise.sh` and ported to `common/lib.sh`: output goes to `debug/re-state-<ts>/` instead of `logs/`, and it no longer starts with `rm -f ../logs/*.*`. It never had a cloud-specific call despite the name. | ✅ |
| E14 | Merge or close branch `aws_gcp_support`. | 🟡 | 5 unmerged commits; `MULTI_CLOUD_COMPLETE.md` calls it "ready to merge". It is **not** ready — see section A. |
| E15 | Bump the AWS/GCP provider pins and `eks_version = "1.29"`. | 🟡 | aws/google pinned `~> 5.0` (resolved 5.100.0 / 5.45.2), behind current majors. **Confirm versions via Context7 first.** |

## F. Feature backlog (from `README.md` and the plan docs)

| | Item | Sev |
|---|---|---|
| F1 | JSON & Search on the Active-Active DB | 🔵 |
| F2 | Rack-zone awareness | 🔵 |
| F3 | Auto Tiering / Flash | 🔵 |
| F4 | 3-way Active-Active (`CLUSTER3` — already read by the test tooling, ignored by the pipeline) | 🔵 |
| F5 | Remote Terraform state, if the rig ever needs >1 operator (ADR 0007) | 🔵 |

---

## G. Version upgrades — ✅ DONE (2026-09-04)

All components moved to their latest available versions. **All four OpenTofu configurations
validate.** Versions confirmed from the GitHub release APIs, PyPI, Docker Hub, the Helm chart
index, the AWS EKS docs and the Redis documentation.

| | Component | Was | Now | Verified |
|---|---|---|---|---|
| G1 | `google` provider | `~> 5.0` → 5.45.2 | **`~> 8.1` → 8.1.0** | `tofu validate` ✅ (clean, no HCL changes needed across 3 majors) |
| G2 | `aws` provider | `~> 5.0` → 5.100.0 | **`~> 6.63` → 6.63.0** | `tofu validate` ✅ |
| G3 | `azurerm` provider | **unpinned** → 5.4.0, **invalid** | **`~> 5.4` → 5.4.0** + `node_provisioning_profile { mode = "Manual" }` on both clusters | `tofu validate` ✅ — was failing |
| G3b | root legacy `main.tf` | unpinned, lock at 4.26.0 | same pin + block; lock refreshed to 5.4.0 | `tofu validate` ✅ |
| G4 | Redis Enterprise operator | unpinned GitHub **`master`** | **`v8.2.0-13`** (2026-08-07) | bundle URL returns HTTP 200 |
| G5 | EKS `eks_version` | `1.29` (out of standard support) | **`1.36`** | newest in EKS standard support; operator 8.2.0 supports 1.33–1.36 |
| G5b | GKE version | `release_channel = "REGULAR"` | unchanged — a channel, not a pin; tracks recent versions automatically | — |
| G6 | `haproxy-ingress` chart | `0.14.4` | **`0.16.1`** | newest stable in the chart index (0.17.0 is alpha) |
| G7 | `memtier_benchmark` image | untagged (`latest`) | **`:2.5.1`** | tag exists on Docker Hub |
| G8 | Python deps | **entirely unpinned** | `redis==8.1.0`, `Flask==3.1.3`, `kubernetes==36.0.3`, `python-dotenv==1.2.3`, `requests==2.34.2`, `urllib3==2.7.0` | `pip install --dry-run` resolves ✅ |
| G8b | `flask/requirements.txt` | **did not exist** | created (Flask, redis, kubernetes) — closes E9 | `pip install --dry-run` resolves ✅ |
| G9 | Load-gen base image | `python:3.12-slim` | **`python:3.14-slim`** | matches the global Python default |

Both copies of `02-setup-haproxy.sh` (`scripts/` and the legacy root one) were updated, so the
currently-working Azure path is not left on old versions.

**Note:** `.terraform.lock.hcl` now exists for all three `providers/*` directories (new,
untracked) and the root lock moved 4.26.0 → 5.4.0. Committing these is what makes the versions
reproducible — see ADR 0007.

**Not done (unrelated hygiene, still open):** E6 (82 shellcheck warnings), E7 (21 ruff findings),
E8 (5 missing shebangs — the only `shellcheck -S error` findings).

---

## H. Deployment logging & diagnostics — ✅ DONE (2026-09-04)

| | Item | Notes |
|---|---|---|
| H1 | `common/lib.sh` | Shared library: `REPO_ROOT` anchoring (CWD-independent), `re_load_config`, `re_log_init/re_log/re_warn/re_die/re_run`, `re_export_tf_vars`, `re_require`. `RE_OFFLINE=1` allows credential-free validation inside the VM. |
| H2 | All deploy scripts log to `debug/` | `debug/<script>-<timestamp>.log`, plus a `<script>-latest.log` symlink. `debug/*` gitignored (`!debug/.gitkeep`). |
| H3 | `scripts/logs.sh` | Browse deployment logs: `list`, `last [script]`, `tail`, `errors` (greps all logs), `bundles`, `clean [days]`. |
| H4 | `scripts/get-logs.sh` | Collects **runtime** diagnostics into `debug/diag-<ts>/`, including **`rladmin status` / `info cluster` / `status databases`** (added 2026-09-07 — the collector was missing the single most useful Active-Active artefact): nodes, pods, events, svc/ingress/pvc, REC/RERC/REAADB/REDB YAML, operator + haproxy + RE pod logs, and **DNS resolution of the API and DB FQDNs** (the usual Active/Active failure cause). `--tail N`, `--cluster X`, `--archive`. Read-only. |
| H4b | `scripts/rladmin.sh` | Run `rladmin` on either cluster (or `--both`), any subcommand, plus `--shell` for the interactive prompt. Cloud-agnostic: pure kubectl exec into `rec-<cluster>-0`. |
| H4c | `scripts/k9s-cluster.sh` | k9s on cluster 1 or 2 with the gcloud identity pinned, so the GKE auth plugin does not authenticate as a different account than the deploy. |
| H5 | `scripts/verify-config.sh` | Proves `config.sh` satisfies every Terraform variable, per provider, **without cloud credentials** — runnable in the VM and in CI. |

---

## I. Operator tooling — backlog

| | Item | Sev | Notes |
|---|---|---|---|
| I1 | **Per-cloud quota/region finder.** A utility per provider that, given a machine type and a node count, reports which regions actually have enough quota to provision the demo. | 🟠 | **Recurring real-world pain**: a deploy fails mid-`tofu apply` on a quota error, after clusters are partly created, and the operator then hunts for a viable region by hand. Wanted: `./scripts/find-regions.sh --machine-type n1-standard-8 --nodes 6` printing eligible regions. Per cloud: GCP `gcloud compute regions describe` / `compute.googleapis.com` quotas (CPUS, CPUS_ALL_REGIONS, IN_USE_ADDRESSES, SSD_TOTAL_GB); AWS `service-quotas get-service-quota` (Running On-Demand Standard instances, vCPU-based) + `ec2 describe-instance-type-offerings` for availability; Azure `az vm list-usage` per location + `az vm list-skus --location` for SKU availability. Must account for the rig needing **2 regions × N nodes**, and check the machine type is even *offered* in the region (not just quota). Read-only, host-side (needs cloud creds). Feed the result back into `config.sh` regions. **Deferred — implement later.** |

---

## J. Deploy entry points — ✅ DONE (2026-09-04)

| | Item | Notes |
|---|---|---|
| J1 | `{gcp,aws,azure}-deploy.sh` (repo root) | One script per cloud, `--destroy` to tear down, plus `--plan-only`, `--yes`, `--skip-preflight`. Exit codes 0/1/2. Shared body in `common/deploy-lib.sh`. |
| J2 | Preflight | Tools, cloud CLI + auth (GCP: **application-default credentials**, not just `gcloud auth login`), project reachable, required APIs enabled, both regions valid **and** machine type actually offered there, DNS zone exists for `DNS_ZONE`, `config.sh` complete, `CLOUD_PROVIDER` matches the invoked script, `tofu validate`. Refuses to touch the cloud on any failure: *"nothing was changed"*. |
| J3 | Confirmation | Shows cloud/clusters/regions/machine/DNS/owner and requires typing `yes`. Refuses non-interactive runs without `--yes`. |
| J4 | Azure safety check | Fails if `AZURE_DNS_RESOURCE_GROUP` equals `AZURE_CLUSTER_RESOURCE_GROUP` — teardown would otherwise delete the DNS zone. |
| J5 | `docs/deployment.md` | Usage, what preflight verifies, per-cloud status, troubleshooting table. |
| J6 | **Identity pinning** | `config.sh` `GCP_ACCOUNT` (+ `AWS_PROFILE_NAME`, `AZURE_SUBSCRIPTION_ID`) → `re_cloud_select_account` exports `CLOUDSDK_CORE_ACCOUNT`/`AWS_PROFILE`/`ARM_SUBSCRIPTION_ID` **process-scoped**. Never mutates global CLI state. Auto-detects when unset: project-matching service account, else probes each credentialed account, else fails listing candidates. Fixes deploying as the wrong identity. |
| J7 | **Three error classes, not two** | `cloud_is_auth_error` (expired credential → blocking, one-line fix) vs `cloud_is_permission_error` (cannot verify → **not** blocking) vs verified-bad (blocking). An expired token used to be reported as *"project does not exist"*. Probed once, early, so the message appears once instead of per-check. |
| J8 | **GCP: CLI credential and ADC checked separately** | OpenTofu only uses ADC; `get-credentials.sh` and `dns-gcp.sh` only use the CLI account. Either can be broken independently. |
| J9 | Log path on every exit path | `re_log_init` installs an `EXIT` trap, so `re_die` and crashes also print `📄 log: …`. |
| J10a | **Per-cloud DNS zone** | `DNS_ZONE` was a single global value; it is now `GCP_DNS_ZONE`/`AWS_DNS_ZONE`/`AZURE_DNS_ZONE` normalised by the `case` block. Each cloud needs its own managed zone, and a shared one would make two simultaneous demos clash on `*.<cluster>` records. |
| J10b | **`GOOGLE_APPLICATION_CREDENTIALS` detection** | It overrides ADC for all client libraries, so it — not the CLI account, not `gcloud auth application-default login` — is the identity that deploys. The preflight now prints its `client_email`/`type` and **blocks when its `project_id` differs from `GCP_PROJECT_ID`** (would otherwise deploy to the wrong project silently). |
| J10c | Preflight speed | Machine-type availability was scanned across all zones (~33 s per region); now one zone is resolved then `machine-types describe` (~1 s). |
| J10d | **Optional `cloudasset` API** | Preflight detects it and offers to enable it (the only interactive prompt left, and non-blocking by design: declining, a non-TTY run, or missing `serviceusage.services.enable` all continue). Without it, `check-tags.sh` audits by name prefix only. |
| J10 | No secrets in logs | `diagnose-gcp.sh` reported token *presence* only; it previously wrote the access token verbatim into `debug/`. |

Note: no `deploy.env` — per the project rule, **all** configuration is in `config.sh`.

---

## K. Single-cluster mode for RDI / SQL demos — backlog (requested 2026-11-25)

Goal: reuse this rig as a plain **REC on one K8s cluster** (no Active-Active) to host a Redis RDI
demo: a SQL database (PostgreSQL, MySQL, …), RDI, Redis Insight, etc. The deploying side lives in
another project (its `ccvm`/`./demo`), which consumes what this one produces.

| | Item | Sev | Notes |
|---|---|---|---|
| K1 | **`gcp-deploy.sh --single`** (name TBD; same for `aws`/`azure`) — deploy ONE cluster + ONE REC, no RERC (step 03) and no REAADB (step 04). | 🟠 | Needs: provider `main.tf` able to create a single region (today `region1`/`region2` are unconditional), `CLUSTER2`/`REC_NAME2` made optional in `common/lib.sh` + `verify-config.sh`, steps 02/05/teardown looping over 1 cluster, preflight checking 1 region. `--destroy` must work in the same mode. Decide: flag only, or also `config.sh` (`AA_MODE=single`) so destroy needs no flag. |
| K2 | **Emit a `.env` of technical facts** into a gitignored dir (proposed `outputs/<cluster>.env`, add to `.gitignore`), written at the end of deploy and refreshed by step 05. | 🟠 | Non-secret by default: cloud, GCP project, region/zone, GKE cluster name, kubeconfig context, `get-credentials` command, namespace (`NS`), REC name, operator version, REC API host/port, DNS zone, ingress class/address, owner/skip_deletion values. **Secrets** (REC admin password) only as a *reference* (secret name + keys), unless explicitly asked. File mode `600`. Never under `debug/` logs. |
| K3 | Document in `docs/architecture/` the contract between this project and the consumer (env var names = a versioned interface; changing them breaks the other project). | 🟡 | Treat as a shared contract doc, like `docs/REDIS_SCHEMA.md` in the global guide. |
| K4 | Verify the REC meets **Redis Software 8.8+ with modules** (RDI requirement). Operator is pinned at `v8.2.0-13`; the REC image comes from that bundle. | 🟠 | Unverified. Likely needs an operator/REC bump and a `redisEnterpriseImageSpec` pin in `templates/rec.yaml`. Check with Context7 / redis-docs before changing. |
| K5 | Capacity profile for a single-cluster demo: REC 3 × 4 CPU/16 Gi leaves ~0 headroom for PostgreSQL + RDI + Insight on 3 × `n1-standard-8`. | 🟡 | Either a larger machine type / node count in this mode, or lower `RE_CPU`/`RE_MEMORY`. |
| K6 | Confirm the operator can manage `RedisEnterpriseDatabase` in **other namespaces** (`rdi`, `sql`, …). The bundle is applied with `-n $NS` and is namespace-scoped by default. | 🟠 | Needs the operator's multi-namespace setup (`ClusterRole` + `rec` cross-namespace config) — not wired today. |
| K7 | **Expose the Cluster Manager UI** on its own host (e.g. `ui.<rec>.<zone>` → `<rec>-ui:8443`, HTTPS/passthrough). The REC ingress only publishes the REST API (`api.*`, 9443) and the DBs, so there is no public UI today; the tunnel (`scripts/webui.sh`) is the only path. | 🟡 | Exposure is acceptable (ADR 0010). The `*.<rec>` wildcard already resolves, so only an Ingress object is needed — no new DNS record. Keep the tunnel working if the exposure is ever removed. |

---

## Recommended order

Revised to the confirmed priority: **GCP first, AWS second, Azure last** (no Azure access at
present). The product constraints are: **one command up, one command down**, DB / management UI /
status console **reachable from anywhere**, demo lifetime **2 hours to several weeks**, and
**security that does not cost usability**.

### Milestone 1 — GCP end-to-end
1. ~~**A3**~~ ✅ `re_export_tf_vars` — all TF_VAR_* from config.sh.
2. ~~**A2**~~ ✅ steps 02–05 anchored on `common/lib.sh`; run from any directory.
3. ~~**A1**~~ ✅ step 02 provider-agnostic — 0 direct cloud calls.
4. ~~**A5**~~ ✅ 0 defaults in every `variables.tf`.
5. ~~**A7**~~ ✅ teardown calls `common/dns-{aws,gcp}.sh`.
6. ~~**G1/G4/G5**~~ ✅ google 8.1.0, operator v8.2.0-13, K8s 1.36.
7. **🔴 NEXT — first real run on GCP, from the host:** `./gcp-deploy.sh --plan-only`,
   then without the flag. Everything above is
   verified credential-free (`tofu validate`, `verify-config.sh`, `helm template`,
   `kubeconform`, CWD-independence). None of it proves a deploy works: quotas, IAM, the
   google 5→8 behaviour changes and DNS delegation are all untested. This is **A10** for GCP
   and the only remaining gate for "1 command up".
8. **B1** — harden the public endpoint (TLS + strong DB password + ACLs) **without** losing
   reachability (ADR 0010). `GCP_REDIS_PORTS` already drops 8001/9443.
9. **D3** — make `launch_test.sh` assert the converged counter, so the core claim is
   machine-checked rather than eyeballed.

### Milestone 2 — CI, so none of it regresses
8. **D1** + **D2** — `shellcheck`, `ruff`, `tofu fmt -check`, `tofu validate` in CI and a
   pre-commit hook. All credential-free, so no cloud secrets needed. Would have caught the
   conflicts in `migration-status.md` §4 on the day they were introduced.

### Milestone 3 — AWS
9. **A8** (ELB `.hostname` vs `.ip` — note the new operator fixes AWS LB annotations),
    **A1** for `common/dns-aws.sh`, **A7** for Route53 cleanup, then **A10**.

### Milestone 4 — Azure, and cleanup
10. **A4** ✅ done (G3) — Azure now validates. Remaining: **A10** (needs access).
11. **E1** — delete the legacy root duplicates (safe once A4 lands), **E3** — fix `README.md`,
    **E4**–**E11** hygiene.

### Deferred
**A12** cross-cloud Active-Active (nice-to-have) · **B7** private clusters (rejected — conflicts
with "from anywhere") · **I1** quota/region finder (wanted, implement later) · section **F**
feature backlog.
