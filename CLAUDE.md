# CLAUDE.md — redis-active-active-multicloud

Project entry map for agents. **Global engineering standards, the security model
(build in the VM, git + deploy from the host, no credentials in the VM) and the
brainstorm→spec→plan→ship→deploy loop live in `~/.claude/CLAUDE.md`. They are not
repeated here.** This file covers only what is specific to this repo.

---

## 1. What this is

A **demo / field-enablement rig** for **Redis Enterprise Active-Active (CRDB)** running on
managed Kubernetes across cloud providers. It provisions two K8s clusters in two regions,
installs the Redis Enterprise operator + HAProxy ingress in each, wires them together as
Redis Enterprise Remote Clusters (RERC), creates one Active-Active database spanning both,
and then provides load generators and a chaos harness to demonstrate that the database
survives node/cluster outages.

It is **not** a product and **not** production infrastructure. It is a disposable,
create-and-destroy demo environment (see `skip_deletion` tagging).

**Audience:** Redis Solution Architects running customer demos and HA/DR proofs.

- Human getting-started guide → `README.md` (Azure path; currently the only working path)
- Agent docs → `docs/` (`product/PRD.md`, `architecture/overview.md`, `specs/`, `adr/`, `TODO.md`)
- **Start here for current state → `docs/migration-status.md` and `docs/TODO.md`**

## 2. Status — read this before trusting any other doc

Branch `aws_gcp_support` (5 unmerged commits, all 2026-05-04) added AWS and GCP support.
Ten root-level `*.md` files from that effort (`MULTI_CLOUD_COMPLETE.md`,
`PHASE{1,2,3}_COMPLETE.md`, …) declared the work **"COMPLETE"** and **"production-ready"**; they
are now archived under **`docs/archive/`** with a warning banner.

**Verified against the code, that is false.** Multi-cloud is roughly **40% done**:

| Layer | Azure | AWS | GCP |
|---|---|---|---|
| Cluster provisioning (Terraform) | works (legacy root path only) | validates, never applied | **cannot apply** (`project_id` unwired) |
| `get-credentials.sh` | present | present | present |
| Steps 02–05 (ingress, operator, REC, RERC, AA DB) | **Azure-hardcoded** | **absent** | **absent** |
| Chaos harness | Azure-hardcoded | dead code | dead code |
| DNS automation | inline `az` in step 02 | dead code | dead code |
| Tag compliance check | works | works | works |

`VALIDATION_CHECKLIST.md` contains **183 unchecked boxes and 0 checked** — nothing in the
multi-cloud effort was ever executed. `terraform.tfstate.backup` only ever contained Azure
resources. Treat the `*_COMPLETE.md` files as **aspirational plans, not status**.

The Active-Active database — the actual point of the project — **can only be created on
Azure**, and only via the legacy root scripts. Details: `docs/migration-status.md`.

### Current priorities (set 2026-09-04)

**Cloud order: GCP → AWS → Azure.** Azure is last despite being the only working cloud — there is
no Azure access at present. Note the consequence: GCP, the top priority, is the *furthest* from
working (it cannot even `tofu apply`).

Hard product constraints, which outrank generic best practice where they conflict — full list in
`docs/product/PRD.md` §3.0:

- **One command up, one command down.**
- **DB, management UI and status console reachable from anywhere** — so no private clusters, no
  IP-scoped firewalls. Security lives in auth + TLS + ACLs instead: **`docs/adr/0010`**.
- Demo lifetime **2 hours to several weeks** → working teardown is a *security* control.
- **Security, but not at the cost of usability.**
- Cross-cloud Active-Active (AKS ↔ EKS) is a **nice-to-have, not a goal**.

Work plan and severity ordering: **`docs/TODO.md`** (Milestone 1 is entirely GCP). Version
upgrade targets: **`docs/TODO.md` §G**.

## 3. Stack

| Concern | Tech |
|---|---|
| Provisioning | **OpenTofu** (`tofu`) 1.12.x — *not* `terraform`; providers azurerm / aws / google |
| Orchestration | **Bash** (~53 scripts) — the primary language of this repo |
| Cluster config | `kubectl`, `helm` (haproxy-ingress 0.14.4), Redis Enterprise K8s operator |
| Templating | `sed` token substitution over `templates/*.yaml` → generated `yaml/` (gitignored) |
| Demo console | **Python 3 + Flask** (`flask/`), Jinja template, `kubernetes` client |
| Load / bench | **Python 3** (`redis-enterprise-testing/`), `redis-py`, `memtier_benchmark`, Docker loadgen |
| Cloud CLIs | `az`, `aws`, `gcloud` (host-side only — never in the VM) |

There is **no `package.json`, no PHP, no MySQL, no Angular, and no Lua** in this repo.

## 4. Install / build / run / test — verified commands

### Verification gates (credential-free, runnable in the VM)

There is no test suite yet. These gates all run in the VM, without cloud credentials:

```bash
# 0. config.sh drives Terraform completely? (per provider, no cloud CLI needed)
./scripts/verify-config.sh all     # expect: 0 defaults, every variable satisfied

# 0b. Kubernetes/Helm — client-side only (kubectl, helm, kubeconform are VM-safe)
helm template haproxy-ingress haproxy-ingress/haproxy-ingress --version 0.16.1 \
  -f templates/haproxy-ingress-values.yaml | kubeconform -kubernetes-version 1.36.0 -summary -

# 1. Shell — the dominant language. 53 tracked scripts.
git ls-files '*.sh' | tr '\n' '\0' | xargs -0 shellcheck -S error     # gate: must stay clean-ish
git ls-files '*.sh' | tr '\n' '\0' | xargs -0 shellcheck -S warning   # 82 findings today

# 2. Terraform/OpenTofu — validate only. NEVER plan/apply/destroy in the VM.
tofu fmt -check -recursive .
for p in aws gcp azure; do (cd "providers/$p" && tofu init -backend=false && tofu validate); done

# 3. Python
git ls-files '*.py' | tr '\n' '\0' | xargs -0 python3 -m py_compile
git ls-files '*.py' | tr '\n' '\0' | xargs -0 ruff check              # 21 findings today
```

Known baseline (2026-09-04): `shellcheck -S error` reports only **SC2148** (missing shebang)
in 5 files. `providers/aws` and `providers/gcp` **validate**; **`providers/azure` FAILS**
validation (see Gotchas). `ruff` reports 21 findings; all Python compiles.

### Deploying the demo (host only — needs cloud credentials)

Per the global security model: **never run these in the VM.** One entry point per cloud:

```bash
cp config.example.sh config.sh          # edit: CLOUD_PROVIDER, GCP_PROJECT_ID, regions, DNS_ZONE, owner

./gcp-deploy.sh --plan-only      # preflight + tofu plan. Changes NOTHING. Do this first.
./gcp-deploy.sh                  # ONE COMMAND UP
./gcp-deploy.sh --destroy        # ONE COMMAND DOWN

./aws-deploy.sh   [--plan-only|--destroy]
./azure-deploy.sh [--plan-only|--destroy]

./check-tags.sh                         # tag compliance (must run from the repo ROOT)
```

Flags: `--plan-only`, `--destroy`, `--skip-preflight`, `--help`. **No confirmation prompt** —
create and destroy run unattended (disposable demo rig); the preflight and `--plan-only` are
the guardrails.
Exit codes: 0 success, 1 failure, 2 bad usage. Details: `docs/deployment.md`.

The preflight refuses to touch the cloud unless tools, credentials, APIs, regions, machine-type
availability, the DNS zone, `config.sh` completeness and `tofu validate` all pass — and says
*"nothing was changed"* when it stops. For GCP it specifically checks
`gcloud auth application-default` credentials, which the OpenTofu provider needs and which
`gcloud auth login` alone does **not** provide.

`scripts/create-all.sh` / `scripts/delete-all-resources.sh` still work directly, but the
`*-deploy.sh` scripts are the supported path — they add the preflight and confirmation.

The pipeline is now provider-agnostic and CWD-independent, but **it has never been run against
a real cloud** — everything below the credential boundary is verified, nothing above it is.
The first `tofu plan`/`apply` on GCP from the host is the outstanding gate (`docs/TODO.md` A10).

The **legacy root scripts** (`./01-create-cluster.sh` … `./04-create-active-active-db.sh`; the legacy `05-get-cluster-info.sh` was deleted) are stale
Azure-only duplicates, superseded by `scripts/`. See `docs/adr/0009`; they are slated for
deletion (`docs/TODO.md` E1).

### Logs & diagnostics — everything lands in `debug/` (gitignored)

Every deploy script logs to `debug/<script>-<timestamp>.log` via `re_log_init`, with a
`<script>-latest.log` symlink.

```bash
./scripts/logs.sh                 # list runs, newest first
./scripts/logs.sh last            # show the most recent log
./scripts/logs.sh last 01-create-cluster
./scripts/logs.sh tail            # follow the running deployment
./scripts/logs.sh errors          # errors/warnings across all logs
./scripts/logs.sh clean 7         # drop logs older than 7 days

./scripts/get-logs.sh             # collect RUNTIME diagnostics -> debug/diag-<ts>/
./scripts/get-logs.sh --archive   # ...and a .tar.gz to share
./scripts/logs.sh bundles         # list collected bundles
```

`get-logs.sh` captures nodes/pods/events/svc/ingress/pvc, the REC/RERC/REAADB/REDB YAML,
operator + haproxy + Redis Enterprise pod logs, and **DNS resolution of the API and DB FQDNs** —
which is the usual cause of an Active/Active failure. Read-only.

### Inspecting the clusters

`providers/*/get-credentials.sh` creates kubeconfig contexts named exactly after the clusters
(`$CLUSTER1` / `$CLUSTER2`), so any kubectl-based tool works directly:

```bash
./scripts/k9s-cluster.sh --list        # contexts + whether they are loaded
./scripts/k9s-cluster.sh 1             # k9s on cluster 1, namespace $NS
./scripts/k9s-cluster.sh 2 default     # cluster 2, explicit namespace
kubectl --context "$CLUSTER1" -n rec get rec,rerc,reaadb

./scripts/rladmin.sh --list            # RE pods per cluster
./scripts/rladmin.sh 1                 # rladmin status on cluster 1
./scripts/rladmin.sh --both            # status on both, one after the other
./scripts/rladmin.sh 1 --shell         # interactive rladmin prompt
./scripts/rladmin.sh 2 status databases
```

`rladmin` is the Redis Enterprise cluster CLI and lives **inside** the RE pods, so there is
nothing to install — the wrapper `kubectl exec`s into `rec-<cluster>-0`. It is cloud-agnostic.

**Why the wrapper:** a GKE kubeconfig authenticates through `gke-gcloud-auth-plugin`, which
resolves the *currently active* gcloud account. Our scripts pin `GCP_ACCOUNT` per process, so a
bare `k9s` can authenticate as a different identity than the one that created the cluster and
fail with a confusing permission error. The wrapper exports the same account, and warns when
`gke-gcloud-auth-plugin` is missing.

### Demo console and load tests

```bash
./launch-flask-console.sh                       # Flask console; reads ../config.sh, so runs from flask/
cd redis-enterprise-testing && ./install-python-reqs-for-test.sh
./launch_test.sh                                # latency/consistency across both regions
cd .. && ./chaos.sh                             # HA harness — Azure only
```

## 5. Module map

| Path | Responsibility |
|---|---|
| `scripts/01..05-*.sh` | The deployment pipeline. **Intended** multi-cloud home. Only `01` is provider-aware. |
| `scripts/create-all.sh` | Runs 01→04, times each step, then 05. |
| `scripts/delete-all-resources.sh` | Provider-aware teardown. |
| `scripts/check-tags-{azure,aws,gcp}.sh` | Per-cloud tag/label compliance checks. Sourced by root `check-tags.sh`. |
| `scripts/chaos.sh` | Node/cluster outage harness. **Azure-hardcoded.** |
| `providers/{azure,aws,gcp}/main.tf` | Per-cloud cluster provisioning (AKS / EKS+VPC+IAM / GKE+VPC). |
| `providers/*/get-credentials.sh` | Writes kubeconfig contexts named `redis-<region>`. Called by `scripts/01`. |
| `providers/*/chaos-provider.sh` | Per-cloud node kill/scale primitives. **DEAD CODE** — nothing calls these. |
| `common/dns-{aws,gcp}.sh` | Route53 / Cloud DNS record management. **DEAD CODE** — nothing calls these. |
| `templates/*.yaml` | `sed`-token templates: `rec`, `rerc`, `rerc-secret`, `re-aa-db`, `webhook`, haproxy values. |
| `yaml/` | Generated manifests. **Gitignored**, must exist as a directory. |
| `flask/` | Flask demo console (`app.py`, `k8s.py`) showing per-region read/write. |
| `redis-enterprise-testing/` | Load generators, latency benchmark, Redis UI/CLI shortcuts, standalone-DB scaling demos. |
| `redis-enterprise-testing/continuous_load/` | Dockerised load generator deployed into K8s. |
| `{gcp,aws,azure}-deploy.sh` (root) | **Host-side entry points — the supported way to run this.** Preflight → confirm → deploy/destroy. `--destroy`, `--plan-only`. Shared body in `common/deploy-lib.sh`. |
| `common/lib.sh` | Shared library: `REPO_ROOT`, `re_load_config`, logging into `debug/`, `re_export_tf_vars`, `re_ns_ensure`, `re_dns_upsert`, `re_ingress_address`. **Source this first in any new script.** |
| `scripts/verify-config.sh` | Proves `config.sh` satisfies every Terraform variable, credential-free. |
| `scripts/logs.sh`, `scripts/get-logs.sh` | Browse deployment logs / collect runtime diagnostics into `debug/`. |
| `scripts/k9s-cluster.sh` | Open k9s on cluster 1 or 2 with the right gcloud identity pinned. |
| `scripts/rladmin.sh` | Run `rladmin` (RE cluster CLI) on either cluster; `--both`, `--shell`. |
| `debug/` | Deployment logs + diagnostic bundles. **Gitignored.** |
| `main.tf`, `variables.tf`, `output.tf` (root) | **Legacy Azure-only** Terraform. Still the only path with a working provider lock. |
| `01..05`, `chaos.sh`, `recreate.sh`, `launch-flask-console.sh` (root) | **Legacy Azure-only duplicates** of `scripts/` — kept, still tracked, and what `README.md` documents. |
| `create-all.sh`, `delete-all-resources.sh`, `check-tags.sh` (root) | Thin wrappers/dispatchers into `scripts/`. **Not** duplicates. |

Root-level `*.md` (11 files) are the AI-generated planning/status artefacts this `docs/` tree
replaces. See `docs/TODO.md` for the consolidation plan.

## 6. Conventions

- **`tofu`, never `terraform`.** Provider config is passed exclusively via exported
  `TF_VAR_*` environment variables from `scripts/01-create-cluster.sh` — there are no
  `.tfvars` files.
- **Cloud identity is pinned per run, never globally.** `config.sh` names the account
  (`GCP_ACCOUNT`, optionally `AWS_PROFILE_NAME`, `AZURE_SUBSCRIPTION_ID`);
  `common/lib.sh::re_cloud_select_account` exports `CLOUDSDK_CORE_ACCOUNT` / `AWS_PROFILE` /
  `ARM_SUBSCRIPTION_ID` **for the script's own process only**. Never call
  `gcloud config set account` — it would silently change the operator's global state in every
  other terminal. When `GCP_ACCOUNT` is empty the deploy script auto-detects: a service account
  matching the project ID, else it probes each credentialed account and takes the first that can
  see the project, else it fails listing the candidates.
- **On GCP there are two independent credentials.** The `gcloud` CLI account (used by
  `providers/gcp/get-credentials.sh` and `common/dns-gcp.sh`) and the **application-default
  credentials** (the only thing the OpenTofu provider uses). Switching one does *not* switch the
  other, so `tofu plan` can succeed while every `gcloud` call 403s — and vice versa. The
  preflight checks both separately.
- **`config.sh` is the single source of truth — enforced, not aspirational.** Every value
  Terraform consumes lives there and reaches it as `TF_VAR_*` via
  `common/lib.sh::re_export_tf_vars`. There are **no `.tfvars` files and no defaults in any
  `providers/*/variables.tf`** (azure 12, aws 12, gcp 19 variables, 0 defaults): a missing value
  fails the plan loudly instead of silently substituting a different one. Verify with
  `./scripts/verify-config.sh all`. Copy the file from `config.example.sh`.
- **Source `common/lib.sh` first in every new script**, then `re_load_config`. It gives you
  `REPO_ROOT` (so the script works from any directory), logging into `debug/`, and
  `re_export_tf_vars`. Do not re-implement `source ../config.sh`.
- **Cluster naming is derived, never literal:** `CLUSTER1=${CLUSTER_PREFIX}-${REGION1}`
  (e.g. `redis-francecentral`). kubectl context name == cluster name. Terraform resource
  names and `get-credentials.sh` must agree with this or step 02 silently targets nothing.
- **Namespace** is `$NS` (default `rec`). Prefer `$NS` over a literal `rec` — steps 04 and
  05 currently hardcode `rec`.
- **Every cloud resource carries `owner` (`firstname_lastname`) and `skip_deletion`
  (`yes`/`no`)** as tags (Azure/AWS) or labels (GCP). AWS/GCP enforce the `owner` format via
  a Terraform `validation` block; Azure does not. This is a cost/compliance requirement —
  `check-tags.sh` audits it.
- **Manifests are generated by `sed` token replacement**, not Helm/Kustomize. Tokens are
  bare uppercase words (`CLUSTER`, `DNS_ZONE`, `NAMESPACE`, `AA_DB_NAME`, `B64_USERNAME`).
  Because `CLUSTER` is a substring of nothing else in the templates this works, but any new
  token must not be a prefix of another.
- **Redis Enterprise Active-Active requires resolvable FQDNs, not IPs** — hence the wildcard
  DNS record `*.<cluster>.<DNS_ZONE>` created in step 02. A real, delegated DNS zone is a hard
  prerequisite, and **the zone is per-cloud**: `GCP_DNS_ZONE`, `AWS_DNS_ZONE`,
  `AZURE_DNS_ZONE` in `config.sh`, normalised to the generic `DNS_ZONE` by the `case` block
  (same pattern as the regions). One zone per cloud avoids two simultaneous demos fighting over
  the same `*.<cluster>` records.
- New provider support = a new `providers/<cloud>/` directory (`main.tf`, `variables.tf`,
  `outputs.tf`, `get-credentials.sh`, `chaos-provider.sh`) + a `case` arm in each
  provider-aware script + `scripts/check-tags-<cloud>.sh` + a `<CLOUD>_*` block in `config.sh`.

## 7. Gotchas

1. ~~**The `scripts/` pipeline is unrunnable — no working directory satisfies it.**~~
   ✅ **FIXED.** Every pipeline script now sources `common/lib.sh` and uses `$REPO_ROOT`,
   `$TEMPLATES_DIR`, `$YAML_DIR`. Verified by running from the repo root, from `scripts/`, and
   from `/tmp` — identical startup. **Always source `common/lib.sh` first in a new script**;
   never re-introduce `source ../config.sh`.
2. **`providers/azure` fails `tofu validate`.** It is a byte-identical copy of the legacy
   root `main.tf`/`variables.tf` with **no `terraform{}` / `required_providers` block**, so
   azurerm floats to v5.x, which requires a `node_provisioning_profile` block that the code
   doesn't have. The legacy root path still works only because `.terraform.lock.hcl` there
   pins azurerm **4.26.0**. AWS and GCP *do* pin (`~> 5.0`) and validate. **Pin azurerm in
   `providers/azure/main.tf`.** (AWS/GCP pins are themselves stale — current majors are
   newer; confirm with Context7 before bumping.)
3. ~~**`config.sh` is decorative for regions and instance types.**~~ ✅ **FIXED.**
   `common/lib.sh::re_export_tf_vars` now exports every `TF_VAR_*` from `config.sh`, and all
   `providers/*/variables.tf` have **0 defaults**, so a missing value fails the plan instead of
   silently substituting a different one. For the record, what was actually wrong: no
   `TF_VAR_region*` or instance type was ever exported; `INSTANCE_TYPE` had **no consumer at
   all**; AWS declared 5 variables it never referenced while hardcoding `1.29` and `t3.xlarge`;
   GCP hardcoded its CIDRs, release channel and `initial_node_count`. Guard:
   `./scripts/verify-config.sh all`.
4. ~~**GCP cannot deploy at all.**~~ ✅ **FIXED.** `TF_VAR_project_id` is now exported by
   `re_export_tf_vars` for both apply and destroy (the destroy gap meant GCP resources could
   leak). The bogus `TF_VAR_aws_account_id` export is gone.
5. ~~**Steps 02–05 are Azure-only regardless of `CLOUD_PROVIDER`.**~~ ✅ **FIXED.** Step 02 has
   **zero** direct cloud calls: credentials via `re_kube_credentials` →
   `providers/$CLOUD_PROVIDER/get-credentials.sh`, DNS via `re_dns_lib`/`re_dns_upsert` →
   `common/dns-$CLOUD_PROVIDER.sh`. The only remaining `az`/`gcloud` calls sit inside
   `case $CLOUD_PROVIDER` arms (step 01's `gcloud config set project`, teardown's inline Azure
   DNS delete). **Still dead code:** all three `providers/*/chaos-provider.sh` (**A6** —
   `chaos.sh` is still Azure-only).
6. **A few scripts remain CWD-bound.** Anchored (run from anywhere): the whole `01`–`05`
   pipeline, `create-all.sh`, `delete-all-resources.sh`, `providers/*/get-credentials.sh`,
   `scripts/{logs,get-logs,verify-config}.sh`. **Still CWD-bound:** `chaos.sh` (expects
   `scripts/`), root `check-tags.sh` (expects the repo root), `flask/*.py` and
   `redis-enterprise-testing/*` (read `../config.sh`).
7. **`config.sh` is committed** and holds personal values (`ThomasManson-temp-AKS`,
   `demo.paquerette.com`, `thomas_manson`). No secrets, but it should be gitignored in favour
   of `config.example.sh` — which is already **ahead** of it (`GCP_CLUSTER_RESOURCE_GROUP`,
   `NODE_COUNT`, `DNS_RESOURCE_GROUP`, `CLUSTER_RESOURCE_GROUP` are missing from `config.sh`).
   Also `DNS_RESOURCE_GROUP` is only set in the `azure` branch of the `case`.
8. **`flask/app.py` runs `app.run(debug=True)`** — the Werkzeug debugger is remote code
   execution if ever bound beyond localhost. Fine for a laptop demo; never expose it.
9. **`README.md` documents the legacy root path** and references
   `redis-enterprise-testing/cli-cluster{1,2}.sh`, which **do not exist** (the files are
   `aadb-cli-cluster{1,2}.sh`).
10. **`yaml/` is gitignored but required.** A fresh clone has no `yaml/` directory, so the
    `sed … > yaml/…` redirects fail. Step 02 also does `rm ./yaml/*.yaml`, which fails on an
    empty directory — and with `set -e` that is fatal.
11. **`tofu` state is local and committed-adjacent.** `terraform.tfstate` sits in the repo
    root (gitignored) with no remote backend, so the demo is single-operator by construction.

## 8. Activated Agent Skills

Activated **per-project** into `.claude/skills/` (gitignored) via `skill-activate`, chosen because
GCP is the current priority. Re-run `/skills-review` as the project evolves.

| Skill | Why |
|---|---|
| `gcloud` | `providers/gcp/get-credentials.sh`, `gcloud config set project` in step 01, all 5 `gcloud` calls in `check-tags-gcp.sh`; needed for TODO A3 |
| `gke-cluster-creation` | `providers/gcp/main.tf` — 2 regional clusters + autoscaling node pools; TODO A5, G1, G5 |
| `gke-networking` | VPC/subnets/firewall + LoadBalancer ingress; central to ADR 0010 and TODO B1/A8 |
| `gke-basics` | kubectl contexts/namespaces/workloads — what steps 02–05 do once ported off `az` |
| `gke-platform-security` | The ADR 0010 trade-off: reachable from anywhere *and* defensible |
| `gke-upgrades` | TODO G5 — K8s version and release channels |
| `gke-cost-optimization` | 2-hour-to-weeks lifetime; node sizing and leak avoidance |

**No AWS/EKS or Azure/AKS skills exist in the local packs** (they are a Google pack). For
Milestones 3–4, use the `find-skills` skill to look for installable equivalents rather than
guessing.

## 9. Versions — all components on latest (2026-09-04)

Applied and verified; **all four OpenTofu configurations validate**. Full table with evidence:
`docs/TODO.md` §G.

| Component | Version |
|---|---|
| `google` provider | `~> 8.1` (8.1.0) — was `~> 5.0` |
| `aws` provider | `~> 6.63` (6.63.0) — was `~> 5.0` |
| `azurerm` provider | `~> 5.4` (5.4.0) — was unpinned **and invalid** |
| Redis Enterprise operator | `v8.2.0-13` — was unpinned GitHub `master` |
| Kubernetes (EKS) | `1.36` — was `1.29` |
| Kubernetes (GKE) | `release_channel = "REGULAR"` (channel, not a pin) |
| haproxy-ingress chart | `0.16.1` — was `0.14.4` |
| `memtier_benchmark` | `:2.5.1` — was untagged |
| Python deps | pinned: `redis==8.1.0`, `Flask==3.1.3`, `kubernetes==36.0.3`, `python-dotenv==1.2.3`, `requests==2.34.2`, `urllib3==2.7.0` |
| Load-gen base image | `python:3.14-slim` — was `3.12-slim` |

**azurerm required a code change, not just a pin:** 5.x mandates a `node_provisioning_profile`
block on `azurerm_kubernetes_cluster`. `mode = "Manual"` preserves the explicit `default_node_pool`
(`"Auto"` would switch AKS to Node Auto Provisioning). Applied to `providers/azure/main.tf` **and**
the legacy root `main.tf`.

When bumping again: re-check with the Context7 MCP, and `tofu validate` all four configurations
(root, `providers/{gcp,aws,azure}`) — the Azure regression shipped because nobody ran it.
