#!/usr/bin/env bash
set -e
USE_RESET=false
USE_PIPE=false

_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../common/lib.sh"
# shellcheck source=../common/lib.sh
. "$_LIB" || { echo "FATAL: failed to load $_LIB" >&2; exit 1; }
re_load_config
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1   # incr_key.py / get_key.py live here
re_cloud_select_account
# Password of the Active-Active DB (empty = no password). Exported so the python
# helpers read it from the environment instead of argv.
REDIS_PASSWORD="$(re_aa_db_password "$CLUSTER1")"
export REDIS_PASSWORD

for arg in "$@"; do
  case "$arg" in
    reset) USE_RESET=true ;;
    pipe)  USE_PIPE=true ;;
  esac
done

KEY="counter"
COUNT1=1000
COUNT2=1000
HOST1="${AA_DB_NAME}-db.${REC_NAME1}.${DNS_ZONE}"
HOST2="${AA_DB_NAME}-db.${REC_NAME2}.${DNS_ZONE}"
if [ -n "${REC_NAME3:-}" ]; then
  HOST3="${AA_DB_NAME}-db.${REC_NAME3}.${DNS_ZONE}"
fi
PORT=443

# Reset key (optional)
if $USE_RESET; then
  echo "🔄 Resetting key..."
  python3 -c "import redis; import os; r=redis.Redis(host='$HOST1', port=$PORT, ssl=True, ssl_cert_reqs=None, password=os.environ.get('REDIS_PASSWORD') or None); r.delete('$KEY')"
fi
# Launch increments in background
echo "🚀 Launching parallel INCR..."
PIPE_ARG=""
if $USE_PIPE; then
  PIPE_ARG="pipe"
fi
python3 incr_key.py $HOST1 $PORT $KEY $COUNT1 $PIPE_ARG &
PID1=$!
python3 incr_key.py $HOST2 $PORT $KEY $COUNT2 $PIPE_ARG &
PID2=$!
if [ -n "$HOST3" ]; then
  python3 incr_key.py $HOST3 $PORT $KEY $COUNT2 $PIPE_ARG &
  PID3=$!
fi

# Delay to allow A/A propagation
echo "⏳ Waiting for process to finish :  $PID1, $PID2${PID3:+, $PID3}"

# Wait
wait $PID1
wait $PID2
if [ -n "$PID3" ]; then
  wait $PID3
fi

# Delay to allow A/A propagation
echo "⏳ Waiting for convergence..."
sleep 2

# Get final value
echo "📥 Reading value from $HOST1"
python3 get_key.py $HOST1 $PORT $KEY
echo "📥 Reading value from $HOST2"
python3 get_key.py $HOST2 $PORT $KEY