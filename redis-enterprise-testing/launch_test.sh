#!/usr/bin/env bash
set -e
USE_RESET=false
USE_PIPE=false

. ../config.sh

for arg in "$@"; do
  case "$arg" in
    reset) USE_RESET=true ;;
    pipe)  USE_PIPE=true ;;
  esac
done

KEY="counter"
COUNT1=1000
COUNT2=1000
HOST1="crdb-anton-db.$CLUSTER1.${DNS_ZONE}"
HOST2="crdb-anton-db.$CLUSTER2.${DNS_ZONE}"
if [ -n "$CLUSTER3" ]; then
  HOST3="crdb-anton-db.$CLUSTER3.${DNS_ZONE}"
fi
PORT=443

# Reset key (optional)
if $USE_RESET; then
  echo "🔄 Resetting key..."
  python3 -c "import redis; r=redis.Redis(host='$HOST1', port=$PORT, ssl=True, ssl_cert_reqs=None); r.delete('$KEY')"
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