#!/usr/bin/env bash

. config.sh

sed -e "s/NAMESPACE/$NS/g"       \
    -e "s/CLUSTER1/$CLUSTER1/g"   \
    -e "s/CLUSTER2/$CLUSTER2/g"    \
    -e "s/AA_DB_NAME/$AA_DB_NAME/g" \
    templates/re-aa-db.yaml > yaml/re-aa-db.yaml

kubectl apply -n rec -f yaml/re-aa-db.yaml