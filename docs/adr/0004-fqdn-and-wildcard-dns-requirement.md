# ADR 0004 — Expose clusters via ingress + wildcard DNS, not public IPs

- **Status:** Accepted (forced by Redis Enterprise)
- **Date:** 2025
- **Evidence:** `config.sh` comment *"Redis Enterprise Active/Active requires FQDNs (not public
  IPs)"*; `az network dns record-set a add-record -n "*.$CLUSTER"` in step 02;
  `templates/rec.yaml` and `rerc.yaml` are parameterised by `DNS_ZONE`; hosts are built as
  `<db>-db.<cluster>.<zone>` and `api.<cluster>.<zone>`.

## Context

Redis Enterprise Active-Active establishes replication between participating clusters by
**FQDN**. Remote-cluster (RERC) definitions and the CRDB endpoints are name-based; IP addresses
are not accepted. Managed-K8s LoadBalancer addresses are also ephemeral across
create/destroy cycles.

## Decision

Install HAProxy ingress in each cluster, then publish a **wildcard A record**
`*.<cluster>.<DNS_ZONE>` pointing at that cluster's ingress address. One record per cluster
covers every Redis Enterprise subdomain (`api.`, `<db>-db.`, …).

## Consequences

**Positive** — one DNS record per cluster regardless of how many databases; stable names across
redeploys; TLS on 443 through the ingress; clients use `rediss://<db>-db.<cluster>.<zone>:443`.

**Negative**
- **A real, owned DNS zone is a hard prerequisite** — the biggest barrier to someone else
  reusing this repo. Currently `demo.paquerette.com`, hardcoded in the committed `config.sh`.
- The DNS zone is **long-lived shared state** outside Terraform, deliberately kept in a separate
  resource group (`AZURE_DNS_RESOURCE_GROUP`) so teardown does not destroy it. Two operators
  using the same `config.sh` will clobber each other's records.
- DNS propagation races cluster readiness; step 02 does not wait for resolution.
- A-records assume an **IP**. AWS ELBs publish a **hostname**, so EKS needs a CNAME/alias — one
  of the reasons AWS support is incomplete (`../specs/dns-management.md` D4).
- TTLs were lowered for fast create/destroy cycles (the `--ttl 10` flag is present but
  commented out).
