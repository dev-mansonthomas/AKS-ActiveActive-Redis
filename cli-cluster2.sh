#!/bin/bash
source ./config.sh

echo "Connecting to CRDB in cluster 2 ($CLUSTER2)..."
redis-cli --tls -h crdb-anton-db.$CLUSTER2.$DNS_ZONE -p 443 --insecure --sni crdb-anton-db.$CLUSTER2.$DNS_ZONE
