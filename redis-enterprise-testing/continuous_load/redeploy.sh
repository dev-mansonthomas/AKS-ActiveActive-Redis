#!/usr/bin/env bash
set -e

echo "🧼 Deleting old pods..."
./remove_pod.sh

echo "⏳ Waiting for all pods to terminate..."
while kubectl get pods -l app=redis-loadgen --no-headers 2>/dev/null | grep -q .; do
  sleep 1
done

echo "🚀 Reapplying deployment from loadgen.yaml..."
kubectl apply -f loadgen.yaml

echo "⏳ Waiting for pod to be ready..."
until kubectl get pods -l app=redis-loadgen -o jsonpath='{.items[0].status.phase}' | grep -q Running; do
  sleep 1
done

echo "♻️ Done. tailing the logs"
kubectl logs -f deploy/redis-loadgen
