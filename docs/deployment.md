# Deployment — host-side entry points

**One script per cloud, at the repository root (plus, once per GCP project, `./gcp-setup.sh` for IAM and APIs — see `gcp-iam.md`). Run these on the host, never in the VM** —
they need cloud credentials, which the VM deliberately does not have.

```bash
./gcp-deploy.sh   --plan-only    # preflight + tofu plan. Changes NOTHING.
./gcp-deploy.sh                  # build the demo   (one command up)
./gcp-deploy.sh   --destroy      # remove everything (one command down)

./aws-deploy.sh   [--plan-only|--destroy]
./azure-deploy.sh [--plan-only|--destroy]
```

| Option | Effect |
|---|---|
| `--plan-only` | Preflight + `tofu plan`, then stop. Nothing is created. **Use this first.** |
| `--destroy` | Tear down: K8s namespaces, Helm releases, DNS records, then `tofu destroy`. |
| `--skip-preflight` | Bypass the checks. Not recommended. |
| `-h` / `--help` | Usage. |

Exit codes: `0` success · `1` failure · `2` bad usage.

## What they do

1. **Identity selection** — pins the account for this run *only*
   (`CLOUDSDK_CORE_ACCOUNT` / `AWS_PROFILE` / `ARM_SUBSCRIPTION_ID`). Your global
   `gcloud`/`aws`/`az` configuration is never modified. Set `GCP_ACCOUNT` in `config.sh` when
   you have several accounts; leave it empty to auto-detect.
2. **Preflight** — refuses to touch the cloud unless everything is in place:
   - tools: `tofu`, `kubectl`, `helm`, `jq`, `curl`, `base64` (+ `dig`, optional)
   - the cloud CLI credential refreshes (an expired token otherwise produces a wall of
     misleading 403s), **and** — separately — that the *application-default* credentials the
     OpenTofu provider actually uses can reach the project. These are two different
     credentials: `gcloud auth login` fixes one, `gcloud auth application-default login` the
     other, and switching the CLI account does not switch ADC
   - the project/subscription/account is reachable
   - required APIs are enabled (GCP: `container`, `compute`, `dns`) — blocking; `./gcp-setup.sh` enables them
   - **optional** API `cloudasset` — if absent, it offers to enable it and
     **never blocks**. It powers the only audit sweep that does not depend on
     our naming convention, which matters because GCP cannot label networks,
     subnets, firewalls or node pools (ADR 0006)
   - both regions exist **and** the configured machine type is genuinely offered there
   - a DNS zone exists for the cloud's zone (`GCP_DNS_ZONE` / `AWS_DNS_ZONE` /
     `AZURE_DNS_ZONE`) — Active/Active needs resolvable FQDNs, so this is a hard prerequisite,
     not a nicety. When the zone is missing, the GCP preflight **lists the zones that do
     exist** in the project, so a naming mismatch is obvious
   - `config.sh` satisfies every Terraform variable (`scripts/verify-config.sh`)
   - `config.sh`'s `CLOUD_PROVIDER` matches the script you invoked
   - `providers/<cloud>` passes `tofu validate`
3. **Banner** — prints cloud, clusters, regions, machine type, DNS zone and owner, then
   proceeds. **There is no confirmation prompt**: this is a disposable demo rig, so create
   and destroy both run unattended. The real guardrails are the preflight (it refuses to
   touch the cloud when anything is wrong) and `--plan-only`.
4. **Deploy** (`scripts/create-all.sh`) or **destroy** (`scripts/delete-all-resources.sh`).
5. **Report** — timings, next commands, and the log path.

Everything is logged to `debug/<cloud>-deploy-<timestamp>.log` (gitignored).
Browse with `./scripts/logs.sh`; collect runtime diagnostics with `./scripts/get-logs.sh`.

Shared implementation: `common/deploy-lib.sh` (sourced, not executable).

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Every `gcloud` query fails with *"Reauthentication failed. cannot prompt during non-interactive execution"* | the CLI credential expired | `gcloud auth login` |
| Wall of 403s naming the wrong email | the globally active account is not the one with access | set `GCP_ACCOUNT` in `config.sh` |
| `tofu plan` works but `gcloud` 403s (or the reverse) | CLI account and ADC are different credentials | `gcloud auth application-default login --account=<the right one>` |
| *"cannot read project metadata"* ⚠️ but everything else is fine | your account lacks `resourcemanager.projects.get` — harmless | ignore; the preflight does not block on it |
| `gcloud auth application-default login` seems to have no effect | **`GOOGLE_APPLICATION_CREDENTIALS` is set and overrides ADC** — gcloud warns about this and it is easy to miss | either `unset GOOGLE_APPLICATION_CREDENTIALS`, or keep it and align the CLI: `gcloud auth activate-service-account --key-file="$GOOGLE_APPLICATION_CREDENTIALS"` |
| *"no Cloud DNS managed zone for X"* | the zone is named differently, or is in another project | the preflight lists the existing zones — copy the right `dnsName` (minus the trailing dot) into `GCP_DNS_ZONE` |
| Clusters land in an unexpected project | the service-account key in `GOOGLE_APPLICATION_CREDENTIALS` belongs to another project | the preflight now blocks on this: it compares the key's `project_id` with `GCP_PROJECT_ID` |

### The three GCP credentials

| # | Credential | Used by | Precedence |
|---|---|---|---|
| 1 | `GOOGLE_APPLICATION_CREDENTIALS` → SA key file | OpenTofu (client libraries) | **wins over 2** |
| 2 | ADC (`~/.config/gcloud/application_default_credentials.json`) | OpenTofu, only if 1 is unset | — |
| 3 | gcloud CLI account (`GCP_ACCOUNT`) | `get-credentials.sh` (kubeconfig), `dns-gcp.sh` (DNS records) | independent of 1 and 2 |

1/2 and 3 are separate identities. **Both must have rights**: OpenTofu creates the clusters,
the CLI writes DNS and fetches kubeconfig. `--plan-only` prints which identity does what.

`./scripts/diagnose-gcp.sh` prints the raw errors the preflight condenses, compares the CLI
identity with the ADC identity, and ends with a real `tofu plan`. It never logs a token.

## Configuration

There is no `deploy.env`: **all configuration lives in `config.sh`** (copy it from
`config.example.sh`). See `../CLAUDE.md` §6. Cloud credentials come from your own
`gcloud` / `aws` / `az` session on the host — never from a file in this repo.

## Status

| Cloud | State (2026-11-27) |
|---|---|
| **GCP** | ✅ Run end to end on a real project: deploy ≈ 13 min, destroy ≈ 15 min, chaos scenarios validated. |
| **AWS** | Provisioning validates, never applied. DNS is incomplete: `common/dns-aws.sh` writes A records while ELBs publish a hostname (needs CNAME) and the EBS CSI driver is missing (`TODO.md` A8, milestone 3). |
| **Azure** | Worked before the rework; not re-verified (no Azure access). |

`--plan-only` is safe on all three. After a deploy, `./scripts/chaos.sh --check-only` is the quickest proof that
both clusters and the Active-Active database are healthy.
