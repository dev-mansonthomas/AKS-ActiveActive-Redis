# ADR 0003 — Generate K8s manifests with `sed` token substitution

- **Status:** Accepted
- **Date:** 2025 (commit `8b06ebb`, "refactor to use templates")
- **Evidence:** `templates/*.yaml` with bare uppercase tokens; `sed -e "s/TOKEN/$VALUE/g" … >
  yaml/…` in steps 02–04; `yaml/` gitignored.

## Context

Five Redis Enterprise custom resources need per-cluster values (cluster name, DNS zone,
namespace, base64 credentials, AA DB name). Options: Helm chart, Kustomize overlays, `envsubst`,
or `sed`.

## Decision

Plain `sed` token replacement from `templates/` into a gitignored `yaml/` directory. Tokens are
bare uppercase words: `CLUSTER`, `DNS_ZONE`, `NAMESPACE`, `AA_DB_NAME`, `CERT`, `B64_USERNAME`,
`B64_PASSWORD`.

Note this applies to the **Redis Enterprise CRs only** — HAProxy ingress *is* installed with
Helm (`haproxy-ingress` 0.14.4 with `templates/haproxy-ingress-values.yaml`).

## Consequences

**Positive** — zero dependencies beyond `sed`; the generated YAML is inspectable in `yaml/`,
which is genuinely useful when demonstrating what the operator consumes; trivially readable by
an SA audience.

**Negative**
- **Unquoted, unescaped substitution.** A value containing `/` or `&` corrupts the output.
- **Bare tokens are collision-prone.** `s/CLUSTER/…/g` would also rewrite `CLUSTER1`,
  `CLUSTER_NAME`, etc. It is safe today only because no template contains such a token — a
  latent trap for anyone adding one. Delimited tokens (`{{CLUSTER}}`) would remove the risk.
- **`yaml/` is gitignored**, so a fresh clone has no such directory and every `> yaml/…`
  redirect fails; step 02's `rm ./yaml/*.yaml` also fails on an empty directory (fatal under
  `set -e`). See `../specs/redis-enterprise-bootstrap.md` D5.
- No schema validation before `kubectl apply`; errors surface as operator rejections.
- Because `jq` is used without `-r`, base64 credential values are substituted **with
  surrounding quotes** — works by luck given where they land in the YAML.
