# Spec — Redis Enterprise bootstrap (step 02)

**Owner:** `scripts/02-setup-haproxy.sh` (legacy: root `02-setup-haproxy.sh`),
`templates/{rec,webhook,haproxy-ingress-values}.yaml`.
**Status (2026-11-27):** ✅ runs on GCP end to end. AWS/Azure not re-run since the rewrite.

## Current state (2026-11-27)

- `02-setup-haproxy.sh` is now a thin driver: it starts **`02a-setup-cluster.sh` once per cluster, in parallel**, each with its own log (`debug/02a-setup-<rec>-<ts>.log`), output prefixed per cluster on the console. Chart/operator versions and `DNS_TTL` are exported to the children.
- HAProxy ingress uses `ssl-passthrough` and routes by **SNI**: database clients must send the host name (see `active-active-database.md`).
- `scripts/create-all.sh` waits for the `-db.` ingress host to exist (polling) instead of a fixed `sleep`.
- Required cloud APIs are enabled by `gcp-setup.sh` (`GCP_REQUIRED_APIS`), not by the deploy.

## Purpose

On each of the two clusters: install an ingress controller, install the Redis Enterprise
operator and its admission webhook, create a RedisEnterpriseCluster (REC), and publish a
wildcard DNS record so the cluster is reachable by FQDN.

## Inputs

`CLUSTER1`, `CLUSTER2`, `NS`, `DNS_ZONE`, `DNS_RESOURCE_GROUP`, `CLUSTER_RESOURCE_GROUP` from
`config.sh`; working kubeconfig contexts from step 01; `helm`, `kubectl`, `jq`; DNS-zone write
permission.

## Outputs

Per cluster: `ingress-controller` namespace with `haproxy-ingress` 0.14.4 and a public
LoadBalancer IP; namespace `$NS` (`rec`) with the operator, `admission-tls` secret and webhook;
`RedisEnterpriseCluster rec-<cluster>` in state `Running`; a wildcard A record
`*.<cluster>.<DNS_ZONE>` → ingress IP; generated `yaml/rec-<cluster>.yaml`,
`yaml/webhook-<cluster>.yaml`.

## Behaviour (as written)

1. `source ../config.sh`, define a `wait_until` retry helper, `cat config.sh`.
2. `helm repo add haproxy-ingress …; helm repo update`.
3. `az aks get-credentials` for both clusters.
4. `rm ./yaml/*.yaml`.
5. For each cluster: `use-context`, `create ns`, `helm install haproxy-ingress --version 0.14.4
   -f templates/haproxy-ingress-values.yaml`, apply the operator `bundle.yaml`, wait for
   `admission-tls`, wait for the REC CRD, `sed templates/rec.yaml` → apply, wait for the REC
   object, wait for the ingress public IP, delete + re-add the wildcard A record via
   `az network dns record-set`, apply the webhook with the extracted cert.
6. Wait (48 × 10 s) for both RECs to reach `Running`.

## Known defects — resolved 2026-09-04

All of D1–D11 were fixed in the rewrite:

| Was | Now |
|---|---|
| D1 aborted on line 39 (`cat config.sh` + `set -e`) | line removed; config comes from `re_load_config` |
| D2 unsatisfiable working directory | `common/lib.sh` provides `$REPO_ROOT`/`$TEMPLATES_DIR`/`$YAML_DIR`; verified from 3 different CWDs |
| D3 Azure-hardcoded (4 `az` calls) | **0 direct cloud calls**; `re_kube_credentials` + `re_dns_lib`/`re_dns_upsert` dispatch on `$CLOUD_PROVIDER`. `common/dns-{aws,gcp}.sh` are finally invoked |
| D4 redundant credential fetch | step 01 and step 02 both call the same `get-credentials.sh` (idempotent) |
| D5 `rm ./yaml/*.yaml` fatal on empty dir | `re_yaml_dir_init --clean` (`mkdir -p` + `rm -f`) |
| D6 operator bundle unpinned (`master`) | pinned `v8.2.0-13`, overridable via `OPERATOR_VERSION` |
| D7 `kubectl create ns` fatal on re-run | `re_ns_ensure` (`--dry-run=client \| apply`); `helm upgrade --install` likewise idempotent |
| D8 assumed `.ip`, breaking on AWS ELB | `re_ingress_address` returns `.ip` **or** `.hostname`. ⚠️ `common/dns-aws.sh` still only writes A records, so `re_dns_upsert` **fails loudly** on an AWS hostname rather than writing a broken record (`../TODO.md` A8) |
| D9 unconditional A-record delete printed errors | delete is `\|\| true` inside `re_dns_upsert` |
| D10 fixed short timeouts | ingress address 6 min, REC Running 10 min, secrets/CRD 2 min |
| D11 bare `sed` token collisions | unchanged (still `sed`), but `CERT` and paths now use `\|` delimiters; see ADR 0003 |

Newly added, beyond the original defect list: a REC-`Running` wait for both clusters, and a
closing `dig` check on `api.<cluster>.<zone>` that warns when DNS has not propagated — the
usual reason step 03 fails.

## Acceptance criteria

- [x] Runs to completion from **any** CWD, with `CLOUD_PROVIDER` respected.
- [x] No `az`/`aws`/`gcloud` command appears in this script.
- [x] `common/dns-aws.sh` and `common/dns-gcp.sh` are actually invoked.
- [x] Handles both LoadBalancer `.ip` (Azure/GCP) and `.hostname` (AWS) when *reading* the address.
- [x] Idempotent: `helm upgrade --install`, `re_ns_ensure`, `kubectl apply`, DNS delete-then-add.
- [x] The operator bundle is pinned (`v8.2.0-13`).
- [x] `shellcheck -S warning` clean.
- [ ] **Both RECs reach `Running` and `*.<cluster>.<DNS_ZONE>` resolves — requires a real
      deployment. Never executed against a cloud.** (`../TODO.md` A10)
- [ ] AWS: write a CNAME/alias for hostname-based ELBs (`../TODO.md` A8).
