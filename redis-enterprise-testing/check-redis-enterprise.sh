#!/usr/bin/env bash
# ============================================================================
# check-redis-enterprise.sh — dump the RE state of both clusters
# ============================================================================
# Renamed from check-redis-enterprise-on-azure.sh: despite the old name it has
# never contained a single cloud-specific call — it is pure kubectl.
#
# ⚠️  Largely superseded by ./scripts/get-logs.sh, which collects the same
#     things plus pod logs, ingress, events and DNS resolution into
#     debug/diag-<ts>/. Kept because it is a quick focused dump.
#
# Output now goes to debug/ (gitignored) instead of logs/, and nothing is
# deleted on the way in.
# ============================================================================

set -uo pipefail

_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../common/lib.sh"
if [ ! -r "$_LIB" ]; then
  echo "FATAL: cannot read $_LIB" >&2
  exit 1
fi
# shellcheck source=../common/lib.sh
. "$_LIB" || { echo "FATAL: failed to load $_LIB" >&2; exit 1; }

re_load_config
re_log_init "check-redis-enterprise"
re_cloud_select_account

OUT="$DEBUG_DIR/re-state-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT"
re_log "📦 writing to ${OUT#"$REPO_ROOT"/}"

for PAIR in "$CLUSTER1:$REC_NAME1" "$CLUSTER2:$REC_NAME2"
do
  CLUSTER="${PAIR%%:*}"; REC_NAME="${PAIR##*:}"
  echo "switching to $CLUSTER"
  kubectl config use-context "$CLUSTER" >/dev/null
  echo "▶️ Context: $(kubectl config current-context)"


  FILE="$OUT/$CLUSTER-get-all.txt"
  echo "#################################################################"
  echo "  kubectl get all for $CLUSTER" in $FILE
  echo "#################################################################"
  kubectl get all -n rec > $FILE
  cat $FILE

  echo "#########################################"
  echo "      External API access for $CLUSTER"
  echo "#########################################"

  REC_UNAME=$(kubectl -n $NS get secret "$REC_NAME" -o jsonpath='{.data.username}' | re_b64_decode)
  echo $REC_UNAME
  REC_PASSWORD=$(kubectl -n $NS get secret "$REC_NAME" -o jsonpath='{.data.password}' | re_b64_decode)
  echo $REC_PASSWORD

  curl https://api.$REC_NAME.$DNS_ZONE:443/v1/cluster --insecure \
  -H "content-type: application/json" \
  -u "$REC_UNAME:$REC_PASSWORD" \
  | jq .name

  FILE="$OUT/$CLUSTER-operator.log"
  echo "#################################################################"
  echo "  REC Operator logs for $CLUSTER" in $FILE
  echo "#################################################################"
  kubectl logs deployment.apps/redis-enterprise-operator -n $NS > $FILE
  tail $FILE

  FILE="$OUT/$CLUSTER-ingress.txt"
  echo "#################################################################"
  echo "  Ingress for $CLUSTER" in $FILE
  echo "#################################################################"
  kubectl get ingress -A > $FILE
  cat $FILE
  echo "kubectl get ingress -o yaml is in file $FILE"
  kubectl get ingress -A -o yaml >> $FILE

  FILE="$OUT/$CLUSTER-rec.txt"
  echo "#################################################################"
  echo "  REC Resources for $CLUSTER" in $FILE
  echo "#################################################################"
  kubectl get rec -A > $FILE
  cat $FILE
  echo "kubectl get rec -o yaml is in file $FILE"
  kubectl get rec -A -o yaml >> $FILE

  FILE="$OUT/$CLUSTER-rerc.txt"
  echo "#################################################################"
  echo "  RERC for $CLUSTER" in $FILE
  echo "#################################################################"
  kubectl get rerc -A > $FILE
  cat $FILE
  echo "kubectl get rerc -o yaml is in file $FILE"
  kubectl get rerc -A -o yaml >> $FILE

  FILE="$OUT/$CLUSTER-redb.txt"
  echo "#################################################################"
  echo "  REDB for $CLUSTER" in $FILE
  echo "#################################################################"
  kubectl get redb -A > $FILE
  cat $FILE
  echo "kubectl get redb -o yaml is in file $FILE"
  kubectl get redb -A -o yaml >> $FILE

  FILE="$OUT/$CLUSTER-reaadb.txt"
  echo "#################################################################"
  echo "  REAADB status for $CLUSTER" in $FILE
  echo "#################################################################"
  kubectl get reaadb -n $NS > $FILE
  cat $FILE
  echo "kubectl describe reaadb $NS is in file $FILE"
  kubectl describe reaadb -n $NS >> $FILE

  FILE="$OUT/$CLUSTER-rladmin-status.txt"
  echo "#################################################################"
  echo "  rladmin status for $CLUSTER" in $FILE
  echo "#################################################################"
  kubectl -n "$NS" exec "$REC_NAME-0" -- rladmin status > $FILE
  cat $FILE

done