# ADR 0001 — Use OpenTofu (`tofu`) instead of Terraform

- **Status:** Accepted
- **Date:** 2025 (pre-dates the multi-cloud branch; recorded retrospectively 2026-09-04)
- **Evidence:** every script invokes `tofu init` / `tofu apply` / `tofu destroy`;
  `.terraform.lock.hcl` resolves providers from `registry.opentofu.org`; `README.md` lists
  *"Switch to opentofu"* among completed work; an earlier commit (`0ec2a6c`) records
  *"use TF_VAR instead of TOFU_VAR"*.

## Context

The project was originally written against Terraform. HashiCorp's licence change to BUSL made
Terraform awkward to redistribute in a public Redis-authored demo repository.

## Decision

Standardise on **OpenTofu**. All provisioning uses the `tofu` binary; the OpenTofu registry
supplies the azurerm/aws/google providers.

## Consequences

**Positive** — MPL-licensed, no redistribution concerns; drop-in CLI compatibility, so existing
HCL and `TF_VAR_*` conventions were unchanged.

**Negative / notes**
- Environment variables remain `TF_VAR_*`, **not** `TOFU_VAR_*` — an early mistake, since
  corrected. Do not "fix" this back.
- Providers resolve from `registry.opentofu.org`, so lock files are not interchangeable with
  Terraform's.
- Contributors must have `tofu` installed; `terraform` will not read the lock files.
- Per the global security model, `tofu` in the VM is **validate-only**
  (`fmt -check`, `init -backend=false`, `validate`). `plan`/`apply`/`destroy` are host-side.
