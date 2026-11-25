# Architecture Decision Records

Reconstructed on **2026-09-04** from the code, git history and the root-level AI-generated
planning documents. No `handover/DECISIONS.md` exists — see `../migration-status.md`.
These were written retrospectively: the *decisions* are evidenced in the code, but the
*deliberation* is reconstructed and is marked where uncertain.

| ADR | Decision | Status |
|---|---|---|
| [0001](0001-use-opentofu-instead-of-terraform.md) | OpenTofu (`tofu`) instead of Terraform | Accepted |
| [0002](0002-provider-directory-abstraction.md) | `providers/<cloud>/` + `CLOUD_PROVIDER` switch | Accepted, **incompletely implemented** |
| [0003](0003-sed-templating-for-manifests.md) | `sed` token substitution for K8s manifests | Accepted |
| [0004](0004-fqdn-and-wildcard-dns-requirement.md) | Ingress + wildcard DNS, not public IPs | Accepted (forced by Redis Enterprise) |
| [0005](0005-config-sh-as-single-source-of-truth.md) | `config.sh` as the only config source | Accepted, **partially honoured** |
| [0006](0006-mandatory-owner-and-skip-deletion-tags.md) | Mandatory `owner` / `skip_deletion` tags | Accepted |
| [0007](0007-local-terraform-state-and-provider-pinning.md) | Local state; pin every provider | Accepted / **violated for Azure** |
| [0008](0008-bash-as-orchestration-language.md) | Bash as the orchestration language | Accepted (at its limit) |
| [0009](0009-root-wrappers-and-legacy-duplicates.md) | Root wrappers + legacy duplicates | **Proposed for supersession** |
| [0010](0010-demo-accessibility-over-network-isolation.md) | Reachability over network isolation; secure with auth + TLS | Accepted 2026-09-04 |

## Decisions that were never made (and should be)

- ~~**Cross-cloud Active-Active**~~ — **decided 2026-09-04: nice-to-have, not a goal.** Two
  regions within one cloud is the demo. Per-cluster provider selection stays unbuilt (ADR 0002).
- **Testing strategy** — there is no test suite and no CI for 53 shell scripts. ADR 0008 covers
  the language choice but nothing decides how correctness is verified.
- **Operator version policy** — `bundle.yaml` is pulled unpinned from GitHub `master`.
- **Secret handling in demos** — admin passwords are printed to stdout and passed on `curl`
  command lines; acceptable for a laptop, undecided in general.
