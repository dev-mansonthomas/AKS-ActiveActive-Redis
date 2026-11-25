# Spec — Teardown

**Owner:** `scripts/delete-all-resources.sh`, root wrapper `delete-all-resources.sh`,
`scripts/recreate.sh`.
**Status:** provider-aware structure in place; **GCP teardown fails**, AWS/GCP DNS cleanup is
explicitly unimplemented.

## Purpose

Remove every billable resource so a demo costs only what it was used for. This matters more
than provisioning: a failed teardown leaks money silently.

## Inputs

`CLOUD_PROVIDER`, `CLUSTER1`/`CLUSTER2`, `NS`, `DNS_ZONE`, `DNS_RESOURCE_GROUP`,
`CLUSTER_RESOURCE_GROUP`/`GCP_PROJECT_ID`, `owner`, `skip_deletion`; authenticated cloud CLI;
Terraform state in `providers/<cloud>/`.

## Outputs

K8s namespaces and Helm releases removed, DNS records removed (Azure only), cloud
infrastructure destroyed via `tofu destroy -auto-approve`, and a total elapsed time in minutes.

## Behaviour

1. `source ../config.sh`, start a timer.
2. For each cluster: `kubectl delete ns $NS`, `kubectl delete ns ingress-controller`,
   `helm uninstall haproxy-ingress` — each guarded with `2>/dev/null || true`.
3. `case $CLOUD_PROVIDER` for DNS: Azure deletes both wildcard records; **AWS and GCP print
   "not yet implemented"**.
4. `cd ../providers/$CLOUD_PROVIDER`, export `TF_VAR_*` per cloud, `tofu destroy -auto-approve`.
5. Return to `scripts/`, print total duration.

`recreate.sh` is a 3-line convenience: teardown followed by create.

## Edge cases

| Case | Behaviour |
|---|---|
| Nothing deployed | K8s/Helm steps are guarded; `tofu destroy` is a no-op |
| Terraform state lost | **`tofu destroy` cannot see the resources → they leak**; only `check-tags.sh` would reveal them |
| Cluster unreachable | `kubectl`/`helm` guarded, so it proceeds to `tofu destroy` |
| `skip_deletion=yes` | **has no effect here** — it is a tag for external reapers, not a guard in this script |
| Finalizers on REC/REAADB | namespace deletion can hang; not handled **(inferred — verify)** |

## Known defects

- **D1 — 🔴 GCP `tofu destroy` fails**, exactly as `apply` does: the `gcp` arm exports no
  `TF_VAR_project_id` and `project_id` has no default → *"No value for required variable"*.
  **GCP resources cannot be destroyed by this script and will leak.**
- **D2 — AWS and GCP DNS records are never cleaned up** (self-documented in the code as
  "not yet implemented"). Stale records accumulate in the zone.
- **D3 — `set -e` plus `tofu destroy`**: a partial destroy aborts the script before the timer,
  leaving no summary and no retry.
- **D4 — no confirmation prompt** on a destructive, `-auto-approve` operation. Per the global
  security model this is host-run and operator-initiated, but a `--yes` guard would be safer.
- **D5 — `skip_deletion` is not honoured**; a resource marked `skip_deletion=yes` is destroyed
  anyway. Either enforce it or document that it is advisory-only.
- **D6 — 2 shellcheck warnings.**
- **D7 — the DNS delete uses `$DNS_RESOURCE_GROUP`**, which is unset for non-Azure providers.

## Acceptance criteria

- [ ] `./delete-all-resources.sh` leaves **zero** billable resources on all three clouds —
      verified by `./check-tags.sh` reporting `TOTAL_CHECKS == 0`.
- [ ] GCP teardown works (`TF_VAR_project_id` exported).
- [ ] DNS records created by step 02 are removed on all three clouds.
- [ ] Partial failures are reported per resource and the script continues, exiting non-zero.
- [ ] The behaviour of `skip_deletion` is enforced or explicitly documented as advisory.
- [ ] `shellcheck -S warning` clean.
