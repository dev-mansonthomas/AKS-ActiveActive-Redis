#!/usr/bin/env bash
source ../config.sh

echo "Connecting to CRDB in cluster 1 ($CLUSTER1)..."
redis-cli --tls -h ${AA_DB_NAME}-db.$CLUSTER1.$DNS_ZONE -p 443 --insecure --sni ${AA_DB_NAME}-db.$CLUSTER1.$DNS_ZONE
