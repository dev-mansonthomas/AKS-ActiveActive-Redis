# Spec — Wildcard DNS management

**Owner:** inline `az network dns` calls in `scripts/02-setup-haproxy.sh`; the `case` block in
`scripts/delete-all-resources.sh`; `common/dns-aws.sh` (Route53), `common/dns-gcp.sh` (Cloud DNS).
**Status:** Azure works (inline). **AWS and GCP modules exist and are dead code.** There is no
`common/dns-azure.sh`.

## Why this exists

Redis Enterprise Active-Active identifies participating clusters by **FQDN, not IP**. Each
cluster needs `*.<cluster>.<DNS_ZONE>` resolving to its ingress LoadBalancer, so that
`<db>-db.<cluster>.<zone>` (data) and `api.<cluster>.<zone>` (REST/UI) resolve. Without this,
RERC trust cannot be established and no AA DB can be created. A real, owned DNS zone is a hard
prerequisite.

## Inputs

`DNS_ZONE`, `DNS_RESOURCE_GROUP` (Azure only), `CLUSTER1`/`CLUSTER2`, the ingress
LoadBalancer address; DNS-zone write permission.

## Outputs

One wildcard A record per cluster, `*.<cluster>` in `<DNS_ZONE>`, pointing at that cluster's
ingress IP. Low/default TTL (step 02 notes TTL was deliberately lowered for
create/destroy cycles; the `--ttl 10` flag is commented out).

## Behaviour

- **Create (Azure, inline in step 02):** `az network dns record-set a delete … -n "*.$CLUSTER" -y`
  then `az network dns record-set a add-record … -a $CLUSTER_IP`.
- **Delete (Azure, teardown):** the same `delete` for both clusters, guarded with
  `2>/dev/null || true`.
- **AWS / GCP:** `common/dns-aws.sh` and `common/dns-gcp.sh` implement the equivalent
  Route53 / Cloud DNS operations — **but no script calls them** (verified: zero references
  outside the AI-generated `.md` files).

## Known defects

- **D1 — AWS/GCP DNS is entirely unwired.** `common/dns-{aws,gcp}.sh` are dead code.
  `scripts/delete-all-resources.sh` states this outright:
  ```
  aws) echo "⚠️  AWS DNS cleanup not yet implemented" ;;
  gcp) echo "⚠️  GCP DNS cleanup not yet implemented" ;;
  ```
  This directly contradicts `MULTI_CLOUD_COMPLETE.md`'s "✅ Multi-cloud DNS Management".
- **D2 — no `common/dns-azure.sh`.** The Azure logic is inline, so the three clouds don't share
  one interface. Extract it for symmetry.
- **D3 — `DNS_RESOURCE_GROUP` is only set in the `azure` arm** of `config.sh`, so it is empty
  for AWS/GCP.
- **D4 — A-only, IP-only.** AWS ELBs publish a **hostname**, requiring a CNAME (or an alias
  record); the current code path reads `.status.loadBalancer.ingress[0].ip` and would produce
  nothing on EKS.
- **D5 — unconditional delete-then-add** prints an error on first run when no record exists.
- **D6 — no propagation wait.** Step 02 proceeds immediately; RERC creation can race DNS.
- **D7 — shellcheck:** `common/dns-aws.sh` 11 warnings, `common/dns-gcp.sh` 8.
- **D8 — the zone is shared, long-lived state.** Two operators running concurrently with the
  same `config.sh` clobber each other's records.

## Acceptance criteria

- [ ] A single interface — `common/dns-<cloud>.sh` for all three clouds, including Azure — with
      identical `create`/`delete` verbs.
- [ ] Step 02 and teardown call it via `$CLOUD_PROVIDER`; no inline `az` DNS calls remain.
- [ ] Handles both IP (A) and hostname (CNAME/alias) LoadBalancer addresses.
- [ ] Teardown removes every record it created, on all three clouds.
- [ ] `dig +short <db>-db.<cluster>.<zone>` resolves before step 03 starts.
- [ ] Idempotent create; no spurious errors on first run.
- [ ] `shellcheck -S warning` clean.
