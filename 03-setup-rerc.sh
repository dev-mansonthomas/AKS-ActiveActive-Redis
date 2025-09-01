#!/usr/bin/env bash

########################################################################################################################
#This script would prepare RERC (Redis Enterprise Remote Cluster) resources and corresponding secrets and then load
#them into two participating clusters.
#
# You can inspect the generated resources under the `./yaml` folder. This script generate the
# Redis Enterprise Active Active Database (RE-AA-DB) resource as `./yaml/re-aa-db.yaml`
# re-aa-db.yaml is applied by 04-create-active-active-db.sh
########################################################################################################################

# load configuration options from file
# change setting like cluster names, DNS zones etc in config.sh
. config.sh
echo "Using configuration in config.sh:"
cat config.sh

# cleaning up ./yaml directory
#rm ./yaml/*.yaml

for CLUSTER in $CLUSTER1 $CLUSTER2
do
  kubectl config use-context $CLUSTER
  B64_USERNAME=$(kubectl -n $NS get secret -o json rec-$CLUSTER | jq .data.username)
  B64_PASSWORD=$(kubectl -n $NS get secret -o json rec-$CLUSTER | jq .data.password)

  # create Redis Enterprise Remote Cluster Secret from template in templates folder
  sed -e "s/CLUSTER/$CLUSTER/g" \
      -e "s/B64_PASSWORD/$B64_PASSWORD/g" \
      -e "s/B64_USERNAME/$B64_USERNAME/g" templates/rerc-secret.yaml > yaml/secret-$CLUSTER.yaml

  # create Redis Enterprise Remote Cluster template in templates folder
  sed -e "s/DNS_ZONE/$DNS_ZONE/g" \
      -e "s/NAMESPACE/$NS/g"      \
      -e "s/CLUSTER/$CLUSTER/g"   \
      templates/rerc.yaml > yaml/rerc-$CLUSTER.yaml

done

echo "Applying generated yaml files"

for CLUSTER in $CLUSTER1 $CLUSTER2
do
  echo "switching to $CLUSTER"
  kubectl config use-context $CLUSTER
  kubectl -n $NS apply -f yaml/secret-$CLUSTER1.yaml
  kubectl -n $NS apply -f yaml/secret-$CLUSTER2.yaml
  kubectl -n $NS apply -f yaml/rerc-$CLUSTER1.yaml
  kubectl -n $NS apply -f yaml/rerc-$CLUSTER2.yaml
done

# We apply this update at the end because the necessary secrets (username/password) are created earlier in the script.
echo "Updating UI session timeout on each cluster..."
for CLUSTER in $CLUSTER1 $CLUSTER2
do
  kubectl config use-context $CLUSTER
  B64_USERNAME=$(kubectl -n $NS get secret -o json rec-$CLUSTER | jq .data.username)
  B64_PASSWORD=$(kubectl -n $NS get secret -o json rec-$CLUSTER | jq .data.password)

  ADMIN_PASSWORD=$(echo "$B64_PASSWORD" | base64 -d)
  ADMIN_USERNAME=$(echo "$B64_USERNAME" | base64 -d)
  UI_FQDN="https://$(kubectl get ingress -n $NS -o jsonpath='{.items[*].spec.rules[*].host}' | tr ' ' '\n' | grep -E '^api\.' | head -1)"
  echo "🔧 Updating timeout on $CLUSTER ($UI_FQDN)..."
  curl -s -k -u "$ADMIN_USERNAME:$ADMIN_PASSWORD" -X PATCH "$UI_FQDN/v1/settings/ui" \
    -H "Content-Type: application/json" \
    -d '{"ui_session_timeout": 86400}'
done
