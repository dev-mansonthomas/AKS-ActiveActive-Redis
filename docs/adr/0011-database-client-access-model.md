# ADR 0011 — How clients reach the Active-Active database

- **Status:** Accepted 2026-11-27
- **Evidence:** GCP deployments 2026-11-25..27; `scripts/04-create-active-active-db.sh` (`re_disable_client_auth`), `scripts/05-get-cluster-info.sh`, `docs/TODO.md` M.

## Context

ADR 0010 says the demo is reachable from anywhere and protected by TLS + a password. On the first real
deployment no client could connect:

- HAProxy passes TLS through and picks the backend by **SNI**; without it the connection lands on the API backend (an HTTP reply: `Protocol error, got "H"`).
- The database ships with `enforce_client_authentication` on, so clients without a certificate get *"certificate required"*. The REAADB CRD has no field for it and `rladmin tune` refuses it.
- `redis-cli -u rediss://:<password>@…` returns `WRONGPASS`; the user must be `default`.

## Decision

1. The database password is **generated** at deployment (K8s secret) and **printed** by step 05 (`--hide-secrets` opts out): this is a disposable rig whose job is to hand the operator a working connection.
2. Step 04, once the REAADB is `active`, switches client-certificate enforcement **off on each instance** through the REST API (`PUT /v1/bdbs/<uid>`, password via stdin, never on a command line). Clients authenticate with TLS + user `default` + password.
3. Step 05 prints a ready command: `redis-cli --insecure --sni <host> -u 'rediss://default:<password>@<host>:443'`. Redis Insight: tick TLS and SNI.

## Consequences

**Positive** — one command up gives a database any client can reach, as ADR 0010 requires; nothing to do by hand.
**Negative** — no mutual TLS: security rests on the password and TLS only (acceptable for a short-lived demo, **not** for anything else). `--insecure` skips server verification because the certificates are self-signed. The REST call runs after the REAADB is active; if the operator ever reconciled the setting back, step 04 would have to be re-run (not observed so far).
