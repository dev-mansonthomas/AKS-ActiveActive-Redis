#!/usr/bin/env bash
set -euo pipefail

docker buildx build --platform linux/amd64 -t thomasmanson458/redis-loadgen:latest --push .