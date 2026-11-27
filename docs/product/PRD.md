# PRD — Redis Enterprise Active-Active, Multi-Cloud Demo Rig

**Status:** partially delivered (Azure only). Last verified against code: **2026-09-04**, branch
`aws_gcp_support` @ `3e7b638`.
**Source:** re-grounded in the code from the root-level AI-generated planning docs
(`MULTI_CLOUD_SUPPORT_PLAN.md`, `MULTI_CLOUD_COMPLETE.md`, `PHASE{1,2,3}_COMPLETE.md`,
`EFFORT_ESTIMATION.md`). No `handover/` directory exists — see `docs/migration-status.md`.

---

## 1. Problem

Redis Enterprise **Active-Active** (CRDB — conflict-free replicated database, geo-distributed
multi-master) is Redis's answer to multi-region write availability. Its value is only credible
when a prospect *watches* it survive a regional failure while writes continue.

Setting that demo up by hand is slow and error-prone: two managed K8s clusters in two regions,
an ingress controller per cluster, the Redis Enterprise operator plus its admission webhook, a
**wildcard DNS record per cluster** (Active-Active requires resolvable FQDNs, not IPs), a
mutual Remote-Cluster (RERC) trust exchange, and only then the Active-Active database. Doing it
live in front of a customer is not viable; doing it once and leaving it running is expensive.

Customers also ask the obvious follow-up: **"does this work on *our* cloud?"** A demo that only
exists on Azure cannot answer that, and cannot demonstrate the genuinely differentiating case —
**Active-Active spanning two different cloud providers.**

## 2. Users

| User | Need |
|---|---|
| **Primary — Redis Solution Architect** (the repo owner) | Stand up a credible Active-Active demo in ~30 min, on the cloud the customer cares about, then destroy it. Show real failover, not slides. |
| **Secondary — Redis SE / field engineer** | Clone, edit one config file, run one script. Minimal Redis-Enterprise-on-K8s expertise assumed. |
| **Tertiary — customer architect** (observer) | See the failure behaviour and latency characteristics on infrastructure that resembles their own. |
| **Constraint-setter — Redis cloud/FinOps** | Every resource tagged `owner` + `skip_deletion` so demo sprawl is attributable and reapable. |

## 3. Goals

### 3.0 Hard product constraints (confirmed by the owner, 2026-09-04)

These are non-negotiable and outrank generic best practice where the two conflict:

| # | Constraint | Consequence |
|---|---|---|
| P1 | **One command to set up.** | `./create-all.sh` must work end-to-end with no manual steps. Currently broken at step 02 on every cloud (`TODO.md` A2). |
| P2 | **One command to tear down.** | `./delete-all-resources.sh` must leave nothing billable *and nothing reachable*. Currently **broken for GCP** (`TODO.md` A3/A7). |
| P3 | **The database, management UI and status console must be reachable from anywhere.** | Rules out private clusters and IP-scoped firewalls. Security moves to auth + TLS + ACLs — see **ADR 0010**. |
| P4 | **Demo lifetime: 2 hours to several weeks.** | Long enough that a public endpoint and cost leakage both matter; reliable teardown is a *security* control, not just hygiene. |
| P5 | **Security, but not at the cost of usability.** | Reject hardening that breaks P1–P3. Do the hardening that doesn't: strong generated passwords, ACLs, TLS, dropping ports the demo doesn't use, Flask debug off. |
| P6 | **Cloud priority: GCP → AWS → Azure.** | Azure is last (no access at present), despite being the only cloud that currently works. Drives the milestone order in `TODO.md`. |
| P7 | **Track current versions.** | Providers, the Redis Enterprise operator, charts, images and Python deps move to latest — see `TODO.md` §G. |

Cross-cloud Active-Active (AKS ↔ EKS) is a **nice-to-have, not a goal**: two regions within one
cloud is the demo.

### 3.1 Functional goals

1. **One config file, one command.** Set `CLOUD_PROVIDER` and regions in `config.sh`, run
   `./create-all.sh`, get a working Active-Active database across two regions.
2. **Provider-agnostic orchestration.** Steps 02–05 (ingress, operator, REC, RERC, AA DB) should
   be identical on every cloud; only provisioning, kubeconfig and DNS differ per provider.
3. **Demonstrable resilience.** A chaos harness that kills nodes / whole clusters while a load
   generator runs, proving zero data loss and continued writes.
4. **Observable proof.** A console and CLI tooling that show per-region reads/writes,
   replication lag and cross-region latency.
5. **Cost hygiene.** Consistent tagging, an automated tag audit, and a reliable one-command
   teardown.
6. **Fully disposable.** Create and destroy repeatedly; no long-lived state beyond the DNS zone.

### Explicit non-goals

- Not production infrastructure: no remote Terraform state, no HA of the demo rig itself, and
  **deliberately no private clusters or IP-scoped network isolation** (ADR 0010 — they would
  break P3). CI/CD is currently absent but *is* wanted (`TODO.md` D1).
- Not a benchmark harness (`redis_connectivity_benchmark.py` is illustrative, not rigorous).
- Not multi-tenant — local state makes it single-operator by construction.
- Not a Redis Enterprise installer/product.

## 4. Scope

### 4.1 Delivered and verified working

- **Azure/AKS end-to-end** Active-Active, via the **legacy root scripts** (`./01…` → `./05…`).
  This is what `README.md` documents and the only path with a working provider lock
  (azurerm 4.26.0). `terraform.tfstate.backup` confirms 2 AKS clusters + 1 resource group were
  really deployed.
- **`config.sh` abstraction layer** — a `CLOUD_PROVIDER` switch mapping `AZURE_*`/`AWS_*`/`GCP_*`
  blocks onto generic `REGION1`, `REGION2`, `INSTANCE_TYPE`, `CLUSTER_RESOURCE_GROUP`, and
  deriving `CLUSTER1`/`CLUSTER2` names.
- **Per-provider Terraform for all three clouds.** AWS (395 lines: VPC, subnets across 2 AZs, 2
  EKS clusters, IAM roles, auto-scaling node groups) and GCP (327 lines: VPC, subnets, 2 GKE
  clusters, node pools) both **pass `tofu validate`** and are pinned to a provider version.
- **Tag/label compliance auditing for all three clouds** — root `check-tags.sh` dispatches to
  `scripts/check-tags-{azure,aws,gcp}.sh`. This is the one feature that is genuinely multi-cloud.
- **Demo & test tooling** — Flask console, Dockerised continuous load generator, memtier
  manifest, cross-region latency script, standalone-DB scale-up/scale-out demos, Redis
  Enterprise UI/CLI shortcuts.
- **Provider-aware provisioning and teardown** — `scripts/01-create-cluster.sh` and
  `scripts/delete-all-resources.sh` both dispatch on `CLOUD_PROVIDER`.

### 4.2 In scope but not (yet) delivered

State on **2026-11-27** (the 2026-09 list of Azure-only steps, an unrunnable pipeline, a GCP that
could not apply and dead DNS code is resolved — see `docs/TODO.md` A1–A8):

- **GCP is delivered and exercised**: one command up (≈13 min), one command down (≈15 min), four
  chaos scenarios (`pod`, `node`, `region`, `region-recover`) validated on real clusters, a
  health-gated harness with an audit trail, and the chaos web console (`docs/product/brief.md`,
  `docs/specs/chaos-webui.md`).
- **AWS**: provisioning validates, never applied. Missing: CNAME for ELB hostnames
  (`common/dns-aws.sh` writes A records), EBS CSI driver, chaos support (`TODO.md` A8, milestone 3).
- **Azure**: worked before the rework; **not re-verified** (no access at present). Azure-specific
  commands in `chaos.sh` were kept verbatim.
- **No CI**: a credential-free suite exists (`./tests/run.sh`: pytest, node, shell with stubs,
  shellcheck, ruff) but nothing runs it automatically (`TODO.md` D).
- **Cross-cloud Active-Active** (e.g. AKS ↔ EKS) was never designed and is a nice-to-have
  (`config.sh` has a single `CLOUD_PROVIDER`).
- Open question for the chaos demo: replication delay of 23–41 s seen after `pod`/`node` (unexplained).

### 4.3 Out of scope

Third cluster / 3-way Active-Active (`CLUSTER3` is declared empty; the deployment pipeline
ignores it, though the test tooling already reads it); JSON & Search on
Active-Active, rack-zone awareness, Auto Tiering/Flash (listed as "Todo" in `README.md`);
Redis Cloud (as opposed to Redis Enterprise Software on K8s).

## 5. Acceptance criteria for "multi-cloud complete"

A provider counts as supported only when **all** of these hold:

1. `CLOUD_PROVIDER=<cloud>` + `./create-all.sh` from a clean clone produces a **healthy
   Active-Active database spanning both regions**, with no manual steps.
2. `config.sh` regions and instance types are actually honoured by Terraform (verifiable in
   `tofu plan` output).
3. `tofu fmt -check` and `tofu validate` pass for `providers/<cloud>/`, with a pinned provider
   version.
4. Wildcard DNS records are created and deleted automatically by the provider's DNS module.
5. `./check-tags.sh` reports 0 failures.
6. `./chaos.sh` can kill a node and a whole cluster on that provider, and the load generator
   shows continued writes.
7. `./delete-all-resources.sh` leaves no billable resources behind.
8. The corresponding `VALIDATION_CHECKLIST.md` section is actually ticked, with evidence.

**Today: Azure meets 1 (legacy path only), 5, 6, 7. AWS meets 3, 5. GCP meets 3, 5.**

Against the hard constraints: **P1 fails on all three clouds** (step 02 aborts), **P2 fails on
GCP** (cannot destroy), **P3 is met but unhardened** (ADR 0010), **P6/P7 are newly set**. GCP —
the top priority — is the furthest from working, which is why `TODO.md` Milestone 1 is entirely
GCP.

## 6. Success metrics

- Time from clean clone to working Active-Active DB: **target < 30 min** (`create-all.sh` already
  times each step; historical Azure runs are the baseline).
- Writes lost during a single-region outage: **0**.
- Manual steps after editing `config.sh`: **0**.
- Untagged billable resources after a run: **0**.
- Clouds on which criterion 1 passes: **target 3 (GCP first), actual 1 (Azure, legacy path)**.
- Manual commands to set up / tear down: **target 1 and 1**.

## 7. Key risks

| Risk | Impact | Note |
|---|---|---|
| Docs assert completion that doesn't exist | An SA promises a customer an AWS demo that cannot be built | The main risk today; `docs/migration-status.md` + this PRD are the mitigation |
| Unpinned/stale provider versions | Silent breakage of a previously working path | Already materialised: `providers/azure` |
| Managed-K8s API drift (AKS/EKS/GKE) | Provisioning breaks without a code change | No CI, so detected only at demo time |
| Redis Enterprise operator pulled from `master` | `bundle.yaml` is fetched unpinned from GitHub `master` in step 02 | Unreproducible builds; a breaking operator release breaks every demo |
| DNS zone is shared, long-lived state | Concurrent operators clobber each other's records | Local Terraform state makes this single-operator anyway |
| Cost leakage | Forgotten clusters | Mitigated by tagging + `check-tags.sh`, provided teardown is run |
| **Public endpoint left running** | A weeks-long internet-reachable Redis endpoint after a failed teardown | Accepted per ADR 0010; mitigation is *working* teardown (`TODO.md` A3/A7) plus strong auth. GCP teardown is currently broken — this is the top risk today. |
| Flask debug mode + public reachability | Werkzeug debugger = RCE | `TODO.md` B2, elevated by ADR 0010 |
