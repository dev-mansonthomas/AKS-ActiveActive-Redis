# Documentation migration status

**Date:** 2026-09-04 · **Branch:** `aws_gcp_support` @ `3e7b638` (5 commits ahead of `main`,
unmerged) · **Nothing was committed** as part of this migration.

---

## 1. The premise had to change: there is no `handover/` directory

The task described an Augment handover at `handover/` containing `STATE.md`, `MEMORY.md`,
`DECISIONS.md`, `PRD.md`, `ARCHITECTURE.md`, `FEATURES.md`, `GUIDELINES.md`.

**No such directory exists, and it never did.** Verified:

```
find . -iname "*handover*" -not -path "./.git/*"     -> (nothing)
git log --all --diff-filter=A -- '*handover*'        -> (nothing)
find . -name STATE.md -o -name DECISIONS.md ...      -> (nothing)
git stash list                                        -> (empty)
docs/                                                 -> existed but was EMPTY
```

The equivalent source material is **11 AI-generated Markdown files at the repository root**
(~3,700 lines), created by the previous ChatGPT/Augment sessions. I used those as the handover
(the table below also lists the hand-written `README.md` for completeness, so it has 12 rows):

| Root file | Lines | Mapped to |
|---|---|---|
| `MULTI_CLOUD_SUPPORT_PLAN.md` | 573 | `docs/architecture/overview.md`, `docs/adr/0002` |
| `README.md` | 594 | kept as the human doc; corrections listed in `TODO.md` E3 |
| `GIT_WORKFLOW.md` | 439 | **dropped** — superseded by the global `~/.claude/CLAUDE.md` |
| `IMPLEMENTATION_SUMMARY.md` | 326 | `docs/architecture/overview.md` |
| `QUICK_START_GUIDE.md` | 349 | `CLAUDE.md` §4 (commands re-verified) |
| `EFFORT_ESTIMATION.md` | 324 | `docs/TODO.md` |
| `VALIDATION_CHECKLIST.md` | 321 | `docs/TODO.md` A10 — **kept**, still useful |
| `README_MULTI_CLOUD.md` | 304 | `docs/product/PRD.md` |
| `MULTI_CLOUD_COMPLETE.md` | 284 | `docs/migration-status.md` §4 (as the primary conflict) |
| `PHASE3_COMPLETE.md` | 269 | `docs/specs/*`, `docs/TODO.md` |
| `PHASE2_COMPLETE.md` | 253 | `docs/specs/*`, `docs/TODO.md` |
| `PHASE1_COMPLETE.md` | 222 | `docs/adr/0009` |

There was also **no `FEATURES.md` and no test suite**, so the specs in `docs/specs/` were derived
from the scripts' actual behaviour rather than from tests.

## 2. What was produced

| Path | Contents |
|---|---|
| `CLAUDE.md` | Project entry map: what it is, stack, verified commands, module map, conventions, **11 gotchas**. References the global security/workflow model rather than restating it. |
| `.claude/settings.json` | 35 allow entries (read-only inspection, linters, `tofu validate`), 29 deny entries (`tofu apply/plan/destroy`, `az`/`aws`/`gcloud`, mutating `kubectl`/`helm`, `git push`, deploy scripts) — encoding the global "no credentialed actions in the VM" rule. |
| `docs/product/PRD.md` | Problem, users, goals, scope split into **delivered / in-scope-but-missing / out-of-scope**, plus 8 acceptance criteria for "multi-cloud complete" and current per-cloud scoring. |
| `docs/architecture/overview.md` | Intended vs **actual** architecture (mermaid), runtime topology, deployment sequence, component reference, Redis data model, security posture, how to add a cloud. |
| `docs/specs/` | Index + **10 feature specs** with inputs, outputs, edge cases, known defects and acceptance criteria. |
| `docs/adr/` | Index + **9 ADRs** reconstructed from code and git history, plus 4 decisions that were never made. |
| `docs/TODO.md` | ~60 items in 6 areas, severity-tagged 🔴🟠🟡🔵, with a recommended order. |
| `docs/migration-status.md` | This file. |

Guidelines were translated per the task: `GIT_WORKFLOW.md`'s content is already covered by the
global `~/.claude/CLAUDE.md` (branch off `main`, Conventional Commits, never push from the VM,
`git-pr-merge` from the host), so it was **dropped rather than duplicated**. Only project-specific
conventions went into `CLAUDE.md` §6 (`tofu` not `terraform`, `TF_VAR_*` only, derived cluster
names, `$NS`, mandatory tags, `sed` tokens, FQDN requirement).

## 3. What I verified by running it

| Check | Result |
|---|---|
| `tofu validate` — `providers/aws` | ✅ **Success! The configuration is valid.** |
| `tofu validate` — `providers/gcp` | ✅ **Success! The configuration is valid.** |
| `tofu validate` — `providers/azure` | ❌ **FAILS** — `Insufficient node_provisioning_profile blocks` ×2 |
| `tofu fmt -check -recursive` | 5 files unformatted |
| GCP `tofu plan` with step 01's exact env | ❌ **`No value for required variable "project_id"`** — reproduced |
| `bash scripts/02-setup-haproxy.sh` | ❌ **aborts: `cat: config.sh: No such file or directory`** — reproduced |
| CWD contradiction | ✅ confirmed — from `scripts/`, `templates/`+`yaml/` are absent; from root, `../config.sh` is absent |
| `shellcheck -S error` (53 scripts) | only SC2148 (missing shebang) in 5 files |
| `shellcheck -S warning` | 82 findings |
| `python3 -m py_compile` (6 files) | ✅ all compile |
| `ruff check` | 21 findings, 9 auto-fixable |
| Secret scan (AWS keys, private keys, `ghp_`, `xox`) | ✅ none |
| `terraform.tfstate.backup` | only ever **2 AKS clusters + 1 resource group** — Azure only |
| Dead-code grep | `providers/*/chaos-provider.sh` and `common/dns-{aws,gcp}.sh`: **zero** references in any `.sh` |
| `VALIDATION_CHECKLIST.md` | **183 unchecked, 0 checked** |

Per the global security model I ran **no** `tofu plan/apply/destroy` against real infrastructure
and **no** `az`/`aws`/`gcloud` commands. Everything above is credential-free.

## 4. Conflicts between the handover and the code — and how I resolved them

**In every case the code won.** These are the substantive ones:

| # | Handover claim | Reality | Resolution |
|---|---|---|---|
| 1 | `MULTI_CLOUD_COMPLETE.md`: *"ALL 3 PHASES COMPLETE"*, *"production-ready"*, *"✅ 3 Cloud Providers"* | Steps 02–05 are Azure-hardcoded; no AA DB can be created on AWS/GCP; `VALIDATION_CHECKLIST.md` 0/183 | Documented as **~40% complete** with a per-layer matrix in `CLAUDE.md` §2 |
| 2 | *"✅ Multi-cloud DNS Management"* | `common/dns-{aws,gcp}.sh` are **never invoked**; teardown literally prints *"AWS DNS cleanup not yet implemented"* | `docs/specs/dns-management.md` D1; TODO A7 |
| 3 | *"✅ Chaos Engineering Capabilities"* across clouds | `chaos.sh` has 9 `az` calls and **zero** `CLOUD_PROVIDER` references; all three `chaos-provider.sh` are dead code | `docs/specs/chaos-engineering.md` D1/D2; TODO A6 |
| 4 | Phase 1 *"restructure for multi-cloud"* | Scripts were **copied**, not ported: `root/02` vs `scripts/02` differ by only `set -e` and the config path. All 8 legacy root scripts remain tracked | ADR 0009, proposed for supersession; TODO E1 |
| 5 | Phase 1 complete implies Azure still works | **`providers/azure` fails `tofu validate`** — copied without a `required_providers` pin, azurerm floated to 5.4.0. The restructure **broke the one working provider** | ADR 0007; TODO A4 (highest-priority fix) |
| 6 | Phase 3 *"GCP COMPLETE"* | GCP `tofu apply` **cannot run** — `project_id` unwired. Reproduced | `docs/specs/cluster-provisioning.md` D2; TODO A3 |
| 7 | `config.sh` is the single source of truth | Regions and instance types are **never** exported as `TF_VAR_*`; `INSTANCE_TYPE` has no consumer. Azure works by coincidence of matching defaults | ADR 0005; TODO A5 |
| 8 | Implied: `./create-all.sh` works | Aborts at step 02 on **every** cloud (`cat config.sh` + the added `set -e`). Reproduced | TODO A2; `CLAUDE.md` gotcha #1 |
| 9 | `EFFORT_ESTIMATION.md`: AWS 3 h, GCP 2 h, total ~9 h | All 5 commits are dated the same day, and none of it was executed. The estimate covers writing the files, not delivering the capability | Re-estimated implicitly via `docs/TODO.md` severity ordering |
| 10 | *"Branches: aws_gcp_support (ready to merge)"* | Not ready — see 1–8 | TODO E14 |
| 11 | Stack assumptions in the task (PHP, MySQL, AngularJS, TypeScript) | **None present.** Actual: Bash (53 scripts), OpenTofu HCL, Python 3 (6 files), YAML | `CLAUDE.md` §3 states this explicitly |
| 12 | Docs describe `CLUSTER3`/3-way AA as unused | The **pipeline** ignores it, but `launch_test.sh` and `redis_connectivity_benchmark.py` **do read it** | Corrected in 4 places rather than repeating the simpler claim |

## 5. Still inferred — not verifiable without cloud credentials

Marked **(inferred — verify)** in the specs:

- Whether `kubectl apply` on an existing REAADB is genuinely idempotent.
- Behaviour when `REGION1 == REGION2` (name collision in one Azure resource group).
- Whether GCP normalises `thomas_manson` as a label value without complaint.
- Whether REC/REAADB **finalizers** hang namespace deletion during teardown.
- Whether the Flask console degrades gracefully when a region is down — the console's entire
  purpose, and untested.
- That AWS EKS provisioning *works*: it validates, but `terraform.tfstate.backup` proves it was
  **never applied**.
- The claimed *"12-30 nodes"* and *"6 regions"* figures: consistent with the HCL, never observed.

## 6. Decisions taken after this report was written

The owner reviewed the findings and set direction, which is now reflected throughout `docs/`:

| Decision | Effect |
|---|---|
| **Cloud priority: GCP → AWS → Azure** (no Azure access at present) | `TODO.md` reordered into 4 milestones; Milestone 1 is entirely GCP. Inverts the original recommendation, which had assumed Azure-first because it was the only cloud that worked. |
| **One command up, one command down; DB / UI / console reachable from anywhere; lifetime 2 h–weeks; security not at the cost of usability** | Captured as hard constraints **P1–P7** in `product/PRD.md` §3.0. |
| **Cross-cloud Active-Active is a nice-to-have, not a goal** | `TODO.md` A12 downgraded to 🔵; ADR 0002 amended; the open question closed in `adr/README.md`. |
| **Archive the superseded root docs** | 10 files moved to `docs/archive/` with a warning banner (`git mv`, rename history preserved, **staged but not committed**). `README.md` and `VALIDATION_CHECKLIST.md` stay at the root. |
| **Update everything to latest** | New `TODO.md` §G with confirmed versions; ADR 0007's follow-up reversed. |
| **Run `/skills-review`** | 7 GCP/GKE skills activated per-project into `.claude/skills/`; see `../CLAUDE.md` §8. |

### The security finding was corrected, not just re-prioritised

This report originally called the GCP `0.0.0.0/0` firewall the highest-severity issue and
recommended scoping it to known client IPs. **That was wrong for this product**: reaching the DB,
management UI and status console from anywhere is a stated requirement. The finding is rewritten
as *harden, do not close* (`TODO.md` B1) and the trade-off is recorded in
**`adr/0010-demo-accessibility-over-network-isolation.md`**.

Two consequences of that ADR:
- **`flask/app.py`'s `app.run(debug=True)` becomes more severe**, not less — a publicly reachable
  Werkzeug debugger is RCE (`TODO.md` B2).
- **Working teardown is now a security control**, not just cost hygiene. GCP currently cannot
  destroy (`TODO.md` A3), which would leave a *public* endpoint running.

## 7. Recommended next 3 actions

Revised for the GCP-first priority:

1. **Make GCP provisionable and destroyable** — `TODO.md` **A3**. Export `TF_VAR_project_id` in
   both `scripts/01-create-cluster.sh` and `scripts/delete-all-resources.sh`. Two lines; without
   them GCP can neither be created nor destroyed, so it blocks both P1 and P2 and carries the
   public-endpoint risk from ADR 0010. Verify with `tofu validate` plus a `tofu plan` dry run on
   the host.

2. **Make the pipeline runnable, then provider-aware** — `TODO.md` **A2** then **A1**. Anchor
   paths with `cd "$(dirname "$0")/.."`, delete the `cat config.sh` lines, add `mkdir -p yaml`
   and an idempotent namespace create (**C1**, **C2**). Then port step 02 off `az` onto
   `providers/$CLOUD_PROVIDER/get-credentials.sh` and the already-written-but-unused
   `common/dns-gcp.sh`. **This is what actually delivers "one command up" (P1).**

3. **Add credential-free CI before the version bumps** — `TODO.md` **D1**/**D2**, then **G1**.
   `shellcheck`, `ruff`, `tofu fmt -check` and `tofu validate` need no cloud secrets and would
   have caught conflicts 5, 6 and 8 the day they shipped. Land that first, because the next step
   is `google` 5.45.2 → **8.1.0** — three major versions on the file the GCP work is editing, and
   worth doing one major at a time with validation between.

**Deferred deliberately:** AWS (Milestone 3) and Azure (Milestone 4). Azure needs only
`azurerm ~> 5.4` + a `node_provisioning_profile` block to validate again, but it is last by
instruction and there is no access to test it.
