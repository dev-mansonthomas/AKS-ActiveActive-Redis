#!/usr/bin/env bash
# ============================================================================
# 05 — Print connection details for the Active/Active deployment
# ============================================================================
# Credentials, FQDNs, connection strings and UI URLs for both clusters.
#
# Usage:
#   ./scripts/05-get-cluster-info.sh                 # shows the password
#   ./scripts/05-get-cluster-info.sh --hide-secrets  # masks it
#
# Passwords are shown BY DEFAULT: this is a disposable demo rig and the whole
# point of this step is to hand the operator something to paste into a UI or a
# redis-cli. Masking by default just meant re-running with a flag every time.
#
# Run from anywhere. Log: debug/05-get-cluster-info-<timestamp>.log
# Read-only.
# ============================================================================

set -uo pipefail

_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../common/lib.sh"
if [ ! -r "$_LIB" ]; then
  echo "FATAL: cannot read $_LIB" >&2
  exit 1
fi
# shellcheck source=../common/lib.sh
. "$_LIB" || { echo "FATAL: failed to load $_LIB" >&2; exit 1; }

# Shown by default; --hide-secrets opts out. --show-secrets still accepted so
# older notes and scripts keep working.
SHOW_SECRETS=1
case "${1:-}" in
  --hide-secrets) SHOW_SECRETS=0 ;;
  --show-secrets) SHOW_SECRETS=1 ;;
  "") ;;
  -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
  *) echo "unknown option: $1 (try --help)" >&2; exit 2 ;;
esac

re_load_config
re_log_init "05-get-cluster-info"

i=1
for PAIR in "$CLUSTER1:$REC_NAME1" "$CLUSTER2:$REC_NAME2"; do
  CLUSTER="${PAIR%%:*}"; REC_NAME="${PAIR##*:}"
  SECRET="$REC_NAME"

  USERNAME=$(kubectl --context="$CLUSTER" -n "$NS" get secret "$SECRET" \
    -o jsonpath='{.data.username}' 2>/dev/null | re_b64_decode) || USERNAME=""
  PASSWORD=$(kubectl --context="$CLUSTER" -n "$NS" get secret "$SECRET" \
    -o jsonpath='{.data.password}' 2>/dev/null | re_b64_decode) || PASSWORD=""

  if [ -z "$USERNAME" ]; then
    re_warn "$CLUSTER: secret '$SECRET' not found in namespace '$NS' — is the REC ready?"
    i=$((i + 1))
    continue
  fi

  # Ingress hosts for this cluster; pick the database one and the API one.
  DB_URL=""
  API_URL=""
  while IFS= read -r host; do
    [ -n "$host" ] || continue
    case "$host" in
      *-db.*|*db*) [ -z "$DB_URL" ] && DB_URL="$host" ;;
      api.*)       [ -z "$API_URL" ] && API_URL="$host" ;;
    esac
  done < <(kubectl --context="$CLUSTER" get ingress -n "$NS" \
             -o jsonpath='{range .items[*].spec.rules[*]}{.host}{"\n"}{end}' 2>/dev/null)

  DB_PASSWORD=$(kubectl --context="$CLUSTER" -n "$NS" get secret "${AA_DB_NAME}-password" \
    -o jsonpath='{.data.password}' 2>/dev/null | re_b64_decode) || DB_PASSWORD=""

  INTERNAL_FQDN="$REC_NAME.$NS.svc.cluster.local"

  if [ "$SHOW_SECRETS" -eq 1 ]; then
    SHOWN_PASSWORD="$PASSWORD"
    SHOWN_DB_PASSWORD="${DB_PASSWORD:-<none>}"
  else
    SHOWN_DB_PASSWORD="<hidden>"
    SHOWN_PASSWORD="<hidden — omit --hide-secrets to show>"
  fi

  echo "##############################################################################################################"
  echo "#📍 Redis Enterprise  : $REC_NAME   (cluster: $CLUSTER)"
  echo "#👤 Username          : $USERNAME"
  echo "#🔑 Password          : $SHOWN_PASSWORD"
  echo "#🌐 Internal FQDN     : $INTERNAL_FQDN"
  if [ -n "$DB_URL" ]; then
    echo "#🔌 Connection String : rediss://:$SHOWN_DB_PASSWORD@$DB_URL:443"
  else
    re_warn "no database ingress host found for $CLUSTER (AA DB not ready?)"
  fi
  [ -n "$API_URL" ] && echo "#🛠  REST API / UI     : https://$API_URL"
  echo "#🖥  RE UI access      : ./scripts/webui.sh ${i}"
  echo "##############################################################################################################"

  i=$((i + 1))
done

