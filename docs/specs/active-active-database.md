# Spec — Active-Active database creation (steps 03–05)

**Owner:** `scripts/03-setup-rerc.sh`, `scripts/04-create-active-active-db.sh`,
`scripts/05-get-cluster-info.sh`, `templates/{rerc,rerc-secret,re-aa-db}.yaml`.
**Status:** works on **Azure via the legacy root scripts** only. In `scripts/` the paths are
broken; on AWS/GCP unreachable because step 02 never completes.

This is the payload of the whole project: the CRDB spanning two regions.

## Purpose

Establish mutual Remote-Cluster (RERC) trust between the two RECs, then create one
RedisEnterpriseActiveActiveDatabase (REAADB) with both clusters as participants, and report the
connection details.

## Inputs

`CLUSTER1`, `CLUSTER2`, `NS`, `DNS_ZONE`, `AA_DB_NAME` from `config.sh`; two RECs in state
`Running` (step 02); the `rec-<cluster>` K8s secret in each cluster; `kubectl`, `jq`, `curl`,
`base64`.

## Outputs

- `yaml/secret-<cluster>.yaml`, `yaml/rerc-<cluster>.yaml` (both applied to **both** clusters).
- `yaml/re-aa-db.yaml` → `RedisEnterpriseActiveActiveDatabase/$AA_DB_NAME` in `$NS`.
- UI session timeout raised to 86400 s on both clusters via `PATCH /v1/settings/ui`.
- Step 05 prints, per cluster: name, admin username, **admin password**, internal FQDN, and a
  `rediss://<db-host>:443` connection string.

## Behaviour

**03** — for each cluster: read `.data.username`/`.data.password` from `rec-<cluster>`, render
`rerc-secret.yaml` and `rerc.yaml`. Then, on **each** cluster, apply **both** clusters' secrets
and RERC objects (mutual trust requires each side to know the other). Finally `curl -k -u
user:pass -X PATCH <api-fqdn>/v1/settings/ui -d '{"ui_session_timeout": 86400}'`.

**04** — render `re-aa-db.yaml` (tokens `NAMESPACE`, `CLUSTER1`, `CLUSTER2`, `AA_DB_NAME`) and
`kubectl apply -n rec`.

**05** — for each cluster, decode the admin secret, list ingress hosts, pick the one containing
`db`, build `rediss://<host>:443`, and print a summary block.

## Edge cases

| Case | Behaviour |
|---|---|
| REC not yet `Running` | the `rec-<cluster>` secret is missing → `jq` yields `null` → invalid manifests applied |
| DNS not propagated | RERC validation fails; the AA DB stays non-ready |
| `AA_DB_NAME` violating `^[a-z]($|[a-z0-9-]*[a-z0-9])$` | rejected by the operator (documented in `config.sh`) |
| Re-run on an existing AA DB | `kubectl apply` is idempotent **(inferred — verify)** |
| No ingress host containing `db` | `DB_URL` unset → connection string becomes `:443` |
| `CLUSTER3` populated | ignored by steps 01–05 (only 2-way is deployed), but `launch_test.sh` and `redis_connectivity_benchmark.py` will try to reach a third host that does not exist |

## Known defects

- **D1 — `cat config.sh` in step 03** (line 16) fails from `scripts/`. No `set -e` here, so it
  is merely noisy — but the following `templates/…` reads and `> yaml/…` writes fail for the
  same CWD reason. See [`redis-enterprise-bootstrap.md`](redis-enterprise-bootstrap.md) D2.
- **D2 — steps 04 and 05 hardcode `-n rec`** instead of `$NS`, so changing `NS` in `config.sh`
  half-breaks the deployment.
- **D3 — `B64_USERNAME`/`B64_PASSWORD` come from `jq .data.username` without `-r`**, so the
  values keep their surrounding quotes and are `sed`-substituted into YAML with them. It works
  today only because the template placement tolerates it — fragile. Use `jq -r`.
- **D4 — the admin password is echoed to stdout** by step 05 and passed via `curl -u` in step 03
  (visible in the process table). Demo-only; never use in a shared environment.
- **D5 — `curl -k`** disables TLS verification.
- **D6 — no readiness wait after step 04.** `create-all.sh` compensates with a blind
  `sleep 5` before step 05; step 05 can therefore read incomplete ingress data.
- **D7 — `URLS=($(kubectl …))`** (step 05) word-splits unquoted — shellcheck **SC2207**.
- **D8 — the UI-timeout `PATCH` is unverified**; a non-2xx response is silently ignored
  (`curl -s` with no `--fail`).
- **D9 — the API FQDN is derived by grepping ingress hosts for `^api\.`**, which silently yields
  an empty URL if the ingress naming ever changes.

## Acceptance criteria

- [ ] After steps 01–04 on a clean clone, `kubectl get reaadb -n $NS` reports the DB ready on
      **both** clusters.
- [ ] A key written through region 1 is readable through region 2 within seconds, and vice versa.
- [ ] Concurrent `INCR` in both regions converges to the sum (CRDT semantics) — this is the
      demo's core claim and must be asserted, not assumed.
- [ ] `$NS` is honoured everywhere; no literal `rec` remains.
- [ ] Steps run from any CWD; `jq -r` used; no password printed unless `--show-secrets` is passed.
- [ ] Step 05 waits for readiness rather than relying on `sleep 5`.
- [ ] `shellcheck -S warning` clean (SC2207 fixed).
