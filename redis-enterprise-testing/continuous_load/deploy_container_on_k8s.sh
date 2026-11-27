#!/usr/bin/env bash
set -euo pipefail

kubectl apply -f loadgen.yaml
kubectl logs -f deploy/redis-loadgen