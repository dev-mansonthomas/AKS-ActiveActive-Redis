#!/usr/bin/env bash
source ../config.sh

echo "Connecting to CRDB in cluster 2 ($CLUSTER2)..."
redis-cli --tls -h ${AA_DB_NAME}-db.$REC_NAME2.$DNS_ZONE -p 443 --insecure --sni ${AA_DB_NAME}-db.$REC_NAME2.$DNS_ZONE
