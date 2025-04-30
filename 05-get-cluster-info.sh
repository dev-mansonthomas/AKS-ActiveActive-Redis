#!/usr/bin/env bash

. config.sh

for CLUSTER in $CLUSTER1 $CLUSTER2
do
  kubectl config use-context $CLUSTER

  USERNAME=$(kubectl -n $NS get secret rec-$CLUSTER -o jsonpath='{.data.username}' | base64 --decode)
  PASSWORD=$(kubectl -n $NS get secret rec-$CLUSTER -o jsonpath='{.data.password}' | base64 --decode)

  URLS=($(kubectl get ingress -n rec -o jsonpath='{.items[*].spec.rules[*].host}'))

  echo "${URLS[@]}"
  # Filtre celles qui contiennent "db"
  for url in "${URLS[@]}"; do
    echo "$url"

    if [[ "$url" == *db* ]]; then
      DB_URL="$url"
      break
    fi
  done
  CONN_STR="$DB_URL:443"

  FQDN=$(kubectl get svc rec-$CLUSTER -n rec -o jsonpath='{.metadata.name}{"."}{.metadata.namespace}{".svc.cluster.local"}')

  echo "##############################################################################################################"
  echo "#📍 Cluster Name      : $CLUSTER"
  echo "#👤 Username          : $USERNAME"
  echo "#🔑 Password          : $PASSWORD"
  echo "#🌐 FQDN              : $FQDN"
  echo "#🔌 Connection String : rediss://$CONN_STR"
  echo "##############################################################################################################"

done