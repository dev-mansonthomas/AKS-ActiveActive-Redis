# Redis Enterprise Active-Active on managed Kubernetes — multi-cloud demo rig

One command builds **two Kubernetes clusters in two regions**, installs Redis Enterprise in each,
links them and creates one **Active-Active (CRDB) database** across both. One command removes
everything. A chaos harness and a web console then show the database surviving the loss of a pod,
a VM, or a whole region — with no human action on the Redis side.

![The chaos console](images/flask_app.png)

It is a **disposable demo for Solution Architects**, not production infrastructure. It is meant to
live a few hours, be reachable from anywhere, and be destroyed afterwards.

| Cloud | State (2026-11-27) |
|---|---|
| **GCP / GKE** | ✅ Validated end to end: deploy ≈ 13 min, destroy ≈ 15 min, chaos scenarios `pod`, `node`, `region`, `region-recover`. [Go to the GCP section](#gcp-gke). |
| **AWS / EKS** | ⚠️ Terraform validates; **never applied**. DNS (CNAME for ELB hostnames) and EBS CSI are not done. [AWS section](#aws-eks). |
| **Azure / AKS** | ⚠️ Worked before the multi-cloud rework; **not re-verified since** (no Azure access). [Azure section](#azure-aks). |

Where to read more: this file is for **humans** (copy-paste, no prior knowledge assumed).
Agents and maintainers: [`CLAUDE.md`](CLAUDE.md) and [`docs/`](docs/) (PRD, specs, architecture, ADRs, TODO).

---

# Part 1 — Common to every cloud

## 1.1 What you need

* A **domain name** you can delegate a sub-domain of (Redis Active-Active needs resolvable FQDNs, not IPs).
* An account on the cloud you choose, with enough quota for **2 × 3 nodes of 8 vCPU / 30 GB** (48 vCPU in total).
* A Redis Enterprise license **only** if you want more than 4 shards per cluster (a 30-day trial runs without one).

Tools on your machine (the **host**, not a VM — they need your cloud credentials):

| Tool | Notes |
|---|---|
| `bash` 5 | macOS ships bash 3.2. `brew install bash`, then put Homebrew's `bin` first in your `PATH` (`/opt/homebrew/bin` on Apple silicon): every script starts with `#!/usr/bin/env bash`, so it picks up that bash, and refuses to run with an older one (message tells you what to do). Check: `bash --version` |
| `tofu` (OpenTofu ≥ 1.6) | **not** `terraform` |
| `kubectl`, `helm`, `jq`, `curl`, `python3` | |
| your cloud CLI | `gcloud` (+ `gke-gcloud-auth-plugin`), `aws` or `az` |
| `redis-cli` ≥ 8 | optional, to talk to the database |
| `k9s` | optional |

## 1.2 Configure: one file, `config.sh`

```bash
cp config.example.sh config.sh     # your personal values; config.sh is gitignored, only config.example.sh is tracked
$EDITOR config.sh                  # set CLOUD_PROVIDER, the block of your cloud, owner, DNS zone
./scripts/verify-config.sh all     # proves config.sh satisfies every Terraform variable (no cloud needed)
```

`config.sh` is the **single source of truth** (no `.tfvars`, no defaults in Terraform): a missing value
fails loudly instead of silently using another one. Every cloud resource is tagged `owner`
(`firstname_lastname`) and `skip_deletion` (`yes`/`no`) — [`./check-tags.sh`](#16-cleanup) audits them.

## 1.3 Up and down

Each cloud has one entry point at the repository root. They all behave the same way:

```bash
./<cloud>-deploy.sh --plan-only    # preflight + plan. Changes NOTHING. Run this first.
./<cloud>-deploy.sh                # ONE COMMAND UP
./<cloud>-deploy.sh --destroy      # ONE COMMAND DOWN
```

The **preflight** refuses to touch the cloud unless tools, credentials, APIs, regions, machine types,
the DNS zone and `config.sh` are all fine, and says *"nothing was changed"* when it stops. There is
**no confirmation prompt** (the environment is disposable). Everything is logged in `debug/`
(gitignored): `./scripts/logs.sh last`, `./scripts/logs.sh errors`.

The deployment is a pipeline, each step also runnable on its own from `scripts/`:

| Step | Does |
|---|---|
| `01-create-cluster.sh` | OpenTofu: VPC/network, two clusters, node pools |
| `02-setup-haproxy.sh` (+ `02a-setup-cluster.sh`, one per cluster **in parallel**) | HAProxy ingress, Redis Enterprise operator, REC, wildcard DNS |
| `03-setup-rerc.sh` | Trust between the two Redis Enterprise clusters (RERC) |
| `04-create-active-active-db.sh` | The Active-Active database; enables client access (see 1.4) |
| `05-get-cluster-info.sh` | Prints URLs, credentials and ready-to-paste commands |

## 1.4 Reach the database and the console

```bash
./scripts/05-get-cluster-info.sh   # URLs, username, passwords, the database connection string, a redis-cli command
```

The database listens behind an HAProxy ingress that routes **by SNI** over TLS passthrough, so every client must send the host name:

```bash
redis-cli --insecure --sni <db-host> -u 'rediss://default:<password>@<db-host>:443' PING
```

* The user is **`default`** (an empty user name gives `WRONGPASS`). The password is generated at deployment and printed by step 05.
* In Redis Insight, tick **TLS** and **SNI** in the connection's security tab.
* Client-certificate enforcement is switched off on the database by step 04 (it is on by default and blocks plain TLS clients).
* The Redis Enterprise admin UI is not published; open it through tunnels: `./scripts/webui.sh` (cluster 1 → <https://localhost:8443>, cluster 2 → <https://localhost:8444>; Ctrl-C closes them).
* Inspect the clusters: `./scripts/k9s-cluster.sh 1`, `./scripts/rladmin.sh --both`, `kubectl --context <cluster> -n rec get rec,rerc,reaadb`.
* A license can be pasted in each admin UI (*Cluster → Configuration → General → License → Change*).

Security model: the demo must be reachable from anywhere, so there are no private clusters or IP
allow-lists; protection is TLS + passwords + least-privilege cloud roles — see
[ADR 0010](docs/adr/0010-demo-accessibility-over-network-isolation.md).

## 1.5 Show it: load, console and chaos

**Concurrent writes** (two clients, one per region, 1000 increments each, the counter ends at 2000):

```bash
cd redis-enterprise-testing && ./install-python-reqs-for-test.sh
./launch_test.sh pipe reset        # no arguments = no pipelining; "reset" zeroes the counter first
```

**The chaos console** — a read-only web page for screen sharing: both clusters' health, the primary
node, the Active-Active database and its sync links, what the running scenario simulates and what to expect.

```bash
./chaos-webui-start.sh        # http://127.0.0.1:5050/   (logs: debug/chaos-webui-*.log, never in your terminal)
./chaos-webui-stop.sh
```

*Optional Redis logo:* it is a trademark asset, so it is not in the repo. Download `Redis_Logo_Red_RGB.svg`
from <https://brand.redis.io/document/18> and save it as `flask/static/brand/Redis_Logo_Red_RGB.svg` (gitignored).

**The chaos harness**: `scripts/chaos.sh` (GCP and Azure; AWS not supported yet).

```bash
./scripts/chaos.sh --check-only                # health gate of BOTH clusters; injects nothing
./scripts/chaos.sh --list                      # pod, node, region, region-recover
./scripts/chaos.sh                             # pod, node, region — pauses before each step (the presenter drives)
./scripts/chaos.sh --scenario node             # one scenario (several: --scenario pod,node)
./scripts/chaos.sh --no-prompt                 # unattended (the region stays down only a few seconds)
./scripts/chaos.sh --scenario pod --pod 0      # force the victim (index or pod name)
./scripts/chaos.sh --scenario region-recover   # resume after an interruption
```

| Scenario | What it breaks | Measured on GCP |
|---|---|---|
| `pod` | force-deletes one Redis Enterprise pod (a node that is neither the cluster primary nor the endpoint holder) | recovered in ≈ 50 s |
| `node` | hard-resets the VM under that pod | ≈ 4–5 min |
| `region` | removes **every node** of one cluster, checks the other region keeps serving, restores the nodes, then runs the REC cluster recovery and `rladmin recover all` | ≈ 7 min |
| `region-recover` | the recovery half of `region`, to finish after an interruption | ≈ 3 min |

Good to know:

* A **health gate** runs first (cloud login, both clusters, REC, RERC, the Active-Active database, a write/read across both regions). If it fails the run stops with **exit 3** and says what to fix. If your cloud login lapsed it prints the command (`gcloud auth login …`).
* The outage is **verified**, not assumed: after `region` the harness insists on **0 Kubernetes nodes**, otherwise the run fails and restores the node pool.
* **Audit trail** for each run in `debug/`: `chaos-<ts>.log` (every command with start/end/exit code, state samples, `kubectl`/`rladmin`/`crdb-cli` snapshots, operator logs) and `chaos-<ts>.events.jsonl` (machine-readable timeline).
* The console is optional: without it `chaos.sh` carries on.
* Exit codes: `0` ok · `1` a check failed · `2` bad usage · `3` health gate failed.

## 1.6 Cleanup

```bash
./<cloud>-deploy.sh --destroy      # namespaces, Helm releases, DNS records, then the infrastructure
./check-tags.sh                    # audit: nothing tagged to you should remain
```

Do not leave it running: two clusters of 3 × 8 vCPU cost real money.

## 1.7 Tests (no cloud needed)

```bash
./tests/run.sh          # pytest + node tests + shell tests with stubbed kubectl/gcloud/curl + shellcheck + ruff
./tests/run.sh shell    # one group: py | js | shell | lint
```

Needs `uv`, a recent `node`, `shellcheck`, `ruff`. The tests never contact a cloud.

## 1.8 Troubleshooting

| Symptom | Likely cause | What to do |
|---|---|---|
| `gcloud` errors such as *Reauthentication failed* | the CLI login expired | `gcloud auth login` (also `gcloud auth application-default login` for OpenTofu) |
| `tofu plan` works but `gcloud` returns 403 (or the opposite) | the CLI account and the application-default credentials are two different identities | align both; details in [`docs/deployment.md`](docs/deployment.md) |
| *no managed zone for …* in the preflight | wrong DNS zone name or project | the preflight lists the zones that exist: copy the right one into `config.sh` |
| `redis-cli`: *certificate verify failed* / `Protocol error, got "H"` | no SNI, or the certificate is self-signed | use `--insecure --sni <host>` |
| `WRONGPASS` | empty user name | use `default:<password>@` |
| `FATAL: bash 5+ is required` | the `bash` first in your `PATH` is macOS's 3.2 | `brew install bash` and put `/opt/homebrew/bin` first in `PATH` |
| `chaos.sh` exits 3 | the health gate found a problem | read the ❌ lines (each has a hint) and the log in `debug/` |
| Redis pods stuck at `1/2` after a chaos run, `rladmin` unreachable | the REC lost its quorum | `./scripts/chaos.sh --scenario region-recover` |
| a command hangs on `kubectl get pods -w` | it is a watch | Ctrl-C |
| Collect everything for a bug report | | `./scripts/get-logs.sh --archive` (writes `debug/diag-<ts>/`) |

---

# Part 2 — One section per cloud

<a id="gcp-gke"></a>
## GCP (GKE)

**Status: validated end to end.** Two regional GKE clusters (3 zones, 1 node per zone, `n1-standard-8`),
one VPC, Cloud DNS records, node pools created inline with the cluster.

**Before the first run**

1. A GCP project with billing, and quota for 24 vCPU in each of the two regions.
2. A **Cloud DNS managed zone** for the sub-domain you chose, delegated at your registrar
   (`gcloud dns managed-zones create redis-demo --dns-name=<zone>. --description=demo`, then add the `NS` records it prints at your registrar; check with `dig NS <zone> +short`).
3. Log in twice (they are two credentials): `gcloud auth login` and `gcloud auth application-default login`.
4. In `config.sh`: `CLOUD_PROVIDER=gcp`, `GCP_PROJECT_ID`, `GCP_ACCOUNT`, `GCP_DNS_ZONE`, `CLUSTER_PREFIX` (unique per person on a shared project), `owner`, `skip_deletion`.
5. **Once per project, as an IAM admin** (never as the deploy identity): create the least-privilege node service account and grant the deploy identity its roles — see [`docs/gcp-iam.md`](docs/gcp-iam.md).
   ```bash
   ./gcp-setup.sh --dry-run     # read what it would change
   ./gcp-setup.sh               # idempotent; also enables the required APIs
   ```

**Run**

```bash
./gcp-deploy.sh --plan-only      # review
./gcp-deploy.sh                  # ≈ 13 min; ends with the connection details (step 05)
./scripts/chaos.sh --check-only  # everything green? then the demo is ready
./gcp-deploy.sh --destroy        # ≈ 15 min (removes whatever is deployed: no flag needed)
./check-tags.sh                  # GCP cannot label networks/firewalls: the audit also sweeps by name via Cloud Asset
```

**Only one cluster** (a plain Redis Enterprise cluster, e.g. for an RDI or SQL demo): add `--single`.

```bash
./gcp-deploy.sh --single --plan-only   # cluster 1 only (the default); --single 2 for cluster 2
./gcp-deploy.sh --single               # one GKE cluster + ingress + operator + REC; no RERC, no database
./scripts/05-get-cluster-info.sh       # REC login and UI hint (there is no database to connect to)
./gcp-deploy.sh --destroy              # same command as for two clusters
```

It builds half of the infrastructure (one subnet, one cluster; the VPC and firewalls are shared) and skips steps 03 and 04.
The selection is refused if it would delete a cluster that is already deployed (for example `--single` while cluster 2 exists):
run `--destroy` first. `chaos.sh` needs both clusters and exits with an explanation on a single-cluster deployment; the chaos
console only shows the missing cluster as unreachable. GCP only for now: `aws-deploy.sh` and `azure-deploy.sh` reject `--single`.

Notes: GKE node-pool operations can be slow (up to an hour on GCP's side), hence `GCP_CLUSTER_TIMEOUT=90m`.
`./scripts/diagnose-gcp.sh` prints the raw errors the preflight condenses and ends with a real `tofu plan`.
Chaos on GCP: the `region` scenario resizes the node pool to 0 (autoscaling off first) and force-deletes the
Redis Enterprise pods, whose termination grace period is one year.

<a id="aws-eks"></a>
## AWS (EKS)

**Status: not verified.** `providers/aws` passes `tofu validate` and the pipeline is provider-agnostic, but
nothing has been applied. Known gaps (tracked in [`docs/TODO.md`](docs/TODO.md), milestone 3):

* ELBs publish a **hostname**, not an IP: `common/dns-aws.sh` must create a CNAME instead of an A record.
* The EBS CSI driver is not installed (Redis Enterprise needs persistent volumes).
* `chaos.sh` does not support AWS yet.

Expected flow once those are done: Route 53 hosted zone delegated at your registrar → `config.sh` with
`CLOUD_PROVIDER=aws` and the `AWS_*` block → `aws sso login` (or your profile) → `./aws-deploy.sh --plan-only` → `./aws-deploy.sh`.

<a id="azure-aks"></a>
## Azure (AKS)

**Status: worked before the multi-cloud rework, not re-verified since.** `./azure-deploy.sh` is the entry
point; the pipeline steps are shared with GCP, so expect to fix small things. If you run it, please note
what you find in [`docs/TODO.md`](docs/TODO.md) (L1).

**Before the first run**

1. `az login`, then `az account show --query id -o tsv` (the subscription ID, set as `AZURE_SUBSCRIPTION_ID` if you have several).
2. **DNS zone.** Redis Active-Active needs FQDNs. Take a domain you own (here `paquerette.com`) and delegate a sub-domain (`demo.paquerette.com`) to Azure:
   ```bash
   az network dns zone create --resource-group <DNS_RESOURCE_GROUP> --name demo.paquerette.com
   ```
   Copy the four `nameServers` from the answer into `NS` records of `demo` at your registrar
   (with the trailing dot), then check: `dig NS demo.paquerette.com +short` should list the four Azure servers.
   Keep this resource group apart from the cluster one: DNS costs almost nothing and can stay forever,
   the clusters cannot.
3. **Quota**: 24 vCPU per region (3 nodes × 8 vCPU) in two regions that support AKS and managed identities:
   `az vm list-usage --location francecentral --output table` (`Standard DSv3 Family vCPUs` must show room).
4. In `config.sh` (the `AZURE_*` block): `CLOUD_PROVIDER=azure`, `AZURE_REGION1/2`, `AZURE_INSTANCE_TYPE` (`Standard_D8s_v3` = 8 vCPU),
   `AZURE_CLUSTER_RESOURCE_GROUP` (temporary, expensive), `AZURE_DNS_RESOURCE_GROUP` (permanent, almost free), `AZURE_DNS_ZONE`, `owner`, `skip_deletion`.

**Run**

```bash
./azure-deploy.sh --plan-only
./azure-deploy.sh                 # about 10 minutes the last time it was measured
./azure-deploy.sh --destroy
```

Chaos on Azure: `node` restarts a VMSS instance (`az vmss restart`), `region` stops the AKS cluster (`az aks stop` / `az aks start`).

---

# Credits and backlog

Based on the work by [antonum](https://github.com/antonum/AKS-ActiveActive-Redis). This fork adds: one-command
multi-cloud deployment driven by `config.sh`, OpenTofu, a parallel installation step, a health-gated chaos
harness with an audit trail, the chaos web console, and a credential-free test suite.

Backlog: [`docs/TODO.md`](docs/TODO.md). Ideas: JSON & Search on Active-Active, rack-zone awareness, Redis Flex.
