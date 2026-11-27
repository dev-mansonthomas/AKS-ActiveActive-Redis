# Architecture Decision Records

Reconstructed on **2026-09-04** from the code, git history and the root-level AI-generated
planning documents. No `handover/DECISIONS.md` exists — see `../migration-status.md`.
These were written retrospectively: the *decisions* are evidenced in the code, but the
*deliberation* is reconstructed and is marked where uncertain.

| ADR | Decision | Status |
|---|---|---|
| [0001](0001-use-opentofu-instead-of-terraform.md) | OpenTofu (`tofu`) instead of Terraform | Accepted |
| [0002](0002-provider-directory-abstraction.md) | `providers/<cloud>/` + `CLOUD_PROVIDER` switch | Accepted; GCP complete, AWS/Azure to verify |
| [0003](0003-sed-templating-for-manifests.md) | `sed` token substitution for K8s manifests | Accepted |
| [0004](0004-fqdn-and-wildcard-dns-requirement.md) | Ingress + wildcard DNS, not public IPs | Accepted (forced by Redis Enterprise) |
| [0005](0005-config-sh-as-single-source-of-truth.md) | `config.sh` as the only config source | Accepted, honoured (`scripts/verify-config.sh all`) |
| [0006](0006-mandatory-owner-and-skip-deletion-tags.md) | Mandatory `owner` / `skip_deletion` tags | Accepted |
| [0007](0007-local-terraform-state-and-provider-pinning.md) | Local state; pin every provider | Accepted (Azure pinned `~> 5.4` since 2026-09) |
| [0008](0008-bash-as-orchestration-language.md) | Bash as the orchestration language | Accepted (tests: ADR 0014) |
| [0009](0009-root-wrappers-and-legacy-duplicates.md) | Root wrappers + legacy duplicates | **Proposed for supersession** |
| [0010](0010-demo-accessibility-over-network-isolation.md) | Reachability over network isolation; secure with auth + TLS | Accepted 2026-09-04 |
| [0011](0011-database-client-access-model.md) | Generated password, SNI, client-cert enforcement off, user `default` | Accepted 2026-11-27 |
| [0012](0012-chaos-console-is-a-display.md) | Chaos console = read-only display driven by the script | Accepted 2026-11-26 |
| [0013](0013-observe-the-outage-do-not-assume-it.md) | Observe the injected failure; hard vs advisory checks; audit trail | Accepted 2026-11-27 |
| [0014](0014-credential-free-test-strategy.md) | Credential-free tests + host-side validation | Accepted 2026-11-27 |
| [0015](0015-single-cluster-selection.md) | Single-cluster deployments: `--single` flag, state is the truth | Accepted 2026-11-27 (GCP) |

## Decisions that were never made (and should be)

- ~~**Cross-cloud Active-Active**~~ — **decided 2026-09-04: nice-to-have, not a goal.** Two
  regions within one cloud is the demo. Per-cluster provider selection stays unbuilt (ADR 0002).
- ~~**Testing strategy**~~ — decided 2026-11-27 (ADR 0014); there is still **no CI**.
- ~~**Operator version policy**~~ — decided: pinned to `v8.2.0-13`, overridable via `OPERATOR_VERSION` (`TODO.md` B5).
- **Secret handling in demos** — admin passwords are printed to stdout and passed on `curl`
  command lines; acceptable for a laptop, undecided in general.
