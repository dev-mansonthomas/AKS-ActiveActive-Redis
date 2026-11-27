#!/usr/bin/env bash
set -uo pipefail

_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../common/lib.sh"
if [ ! -r "$_LIB" ]; then
  echo "FATAL: cannot read $_LIB" >&2
  exit 1
fi
# shellcheck source=../common/lib.sh
. "$_LIB" || { echo "FATAL: failed to load $_LIB" >&2; exit 1; }

re_load_config
re_log_init "04-create-active-active-db"
if re_is_single; then
  re_die "step 04 creates an Active-Active database across TWO clusters: not applicable to a single-cluster deployment"
fi
re_yaml_dir_init

# --- Database password ------------------------------------------------------
# The DB endpoint is reachable from anywhere (ADR 0010), so it must never be
# passwordless. Generate one ONCE (idempotent: an existing secret is reused) and
# put the same value in both clusters. The password is never logged or written
# to yaml/; it is fed to kubectl through a file descriptor.
AA_DB_SECRET="${AA_DB_NAME}-password"
DB_PASSWORD=$(kubectl --context="$CLUSTER1" -n "$NS" get secret "$AA_DB_SECRET" \
                -o jsonpath='{.data.password}' 2>/dev/null | re_b64_decode) || DB_PASSWORD=""
if [ -z "$DB_PASSWORD" ]; then
  DB_PASSWORD=$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32)
  [ "${#DB_PASSWORD}" -eq 32 ] || re_die "could not generate a database password"
  re_log "🔑 Generated a new password for '$AA_DB_NAME' (secret $AA_DB_SECRET)"
else
  re_log "🔑 Reusing existing secret $AA_DB_SECRET"
fi
for CLUSTER in "$CLUSTER1" "$CLUSTER2"; do
  kubectl --context="$CLUSTER" -n "$NS" create secret generic "$AA_DB_SECRET" \
      --from-file=password=<(printf '%s' "$DB_PASSWORD") \
      --dry-run=client -o yaml \
    | kubectl --context="$CLUSTER" -n "$NS" apply -f - >/dev/null \
    || re_die "$CLUSTER: failed to create secret $AA_DB_SECRET"
done
unset DB_PASSWORD

re_render re-aa-db.yaml "$YAML_DIR/re-aa-db.yaml" \
  "REC_NAME_1=$REC_NAME1" "REC_NAME_2=$REC_NAME2" "AA_DB_SECRET=$AA_DB_SECRET"

re_log "Creating Active/Active database '$AA_DB_NAME' spanning $CLUSTER1 and $CLUSTER2"

# The REAADB object only needs to be applied once; the operator propagates it
# to the participating clusters via the RERC trust established in step 03.
re_run kubectl --context="$CLUSTER1" apply -n "$NS" -f "$YAML_DIR"/re-aa-db.yaml \
  || re_die "failed to apply $YAML_DIR/re-aa-db.yaml"

re_log "Waiting for the AA database to become active (up to 10 min)..."
for _ in $(seq 1 60); do
  state=$(kubectl --context="$CLUSTER1" get reaadb "$AA_DB_NAME" -n "$NS" \
            -o jsonpath='{.status.status}' 2>/dev/null || true)
  if [ "$state" = "active" ]; then
    re_log "✅ Active/Active database '$AA_DB_NAME' is active"
    break
  fi
  re_log "   status=${state:-<pending>}"
  sleep 10
done

if [ "${state:-}" != "active" ]; then
  re_warn "AA database '$AA_DB_NAME' is not active yet (last status: ${state:-<none>})"
  re_warn "Collect diagnostics with: ./scripts/get-logs.sh"
  exit 1
fi
# --- Client certificates are NOT required (ADR 0010) -------------------------
# A new AA database is created with enforce_client_authentication=enabled: the
# TLS handshake then fails ("certificate required") for every client that has no
# client certificate — redis-cli, redis-py, Flask, the benchmark. Access is
# protected by TLS + the database password instead. The REAADB CRD has no field
# for this, so it is set through the REST API of each instance (verified by hand
# on GCP 2026-11-26: PUT /v1/bdbs/<uid> -> 200, `rladmin info db` -> False).
# The cluster password goes through stdin (curl -K -), never on a command line.
# (re_disable_client_auth lives in common/lib.sh: it retries while the peer instance is created)
re_log "Disabling the client-certificate requirement on both instances"
re_disable_client_auth "$CLUSTER1" "$REC_NAME1" || exit 1
re_disable_client_auth "$CLUSTER2" "$REC_NAME2" || exit 1
