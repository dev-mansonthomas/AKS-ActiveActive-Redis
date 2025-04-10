#!/bin/bash
source ../config.sh

echo "Connecting to CRDB in cluster 1 ($CLUSTER1)..."
redis-cli --tls -h crdb-anton-db.$CLUSTER1.$DNS_ZONE -p 443 --insecure --sni crdb-anton-db.$CLUSTER1.$DNS_ZONE
