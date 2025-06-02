#!/usr/bin/env bash

###############################################################################
# Redis Enterprise - AKS Active-Active Chaos Testing Script
#
# This script simulates failure and recovery scenarios for a Redis Enterprise
# deployment running in Active-Active mode on Azure Kubernetes Service (AKS).
#
# It allows the operator to:
#  - Select a region where the chaos scenario will be applied
#  - Observe Redis cluster behavior during node failure, VMSS restart, and AKS restarts
#  - Demonstrate Redis Enterprise resilience and automated recovery
#
# Prerequisites:
#  - Azure CLI authenticated and context properly set
#  - config.sh file sourcing variables: CLUSTER1, CLUSTER2, CLUSTER3, NS, etc.
#  - Flask benchmark app (flask/app.py) should be running to visualize impact
#
# Steps performed:
#  1. Parse optional region argument, defaulting to $CLUSTER1
#  2. Remind to launch benchmark application
#  3. Switch kubectl context to the selected region's AKS cluster
#  4. Display AKS node info
#  5. Find VMSS name and resource group using az vmss list
#  6. Record expected pod count in namespace $NS
#  7. Force delete a Redis Enterprise pod to simulate failure
#  8. Wait for Redis Enterprise cluster to recover and all pods to be Running
#  9. Restart a VMSS instance and wait for recovery
# 10. Stop the AKS cluster (region outage simulation) and wait until it is stopped
# 11. Prompt operator to verify access from other region
# 12. Restart the AKS cluster and wait until it is running
# 13. Patch the REC object to initiate cluster recovery
# 14. Wait for Redis Enterprise cluster and pods to recover
# 15. Trigger full database recovery with rladmin
# 16. Prompt for final verification that replication works as expected
#
# Usage:
#   ./chaos.sh             # Uses $CLUSTER1 from config.sh by default
#   ./chaos.sh redis-ukwest  # Argument must match either $CLUSTER1 or $CLUSTER2 from config.sh
###############################################################################
set -euo pipefail

# Load configuration
. ./config.sh

# Default region is redis-francecentral
region="$CLUSTER1"

# Parse optional command-line argument to override region
if [[ $# -gt 0 ]]; then
  if [[ "$1" == "$CLUSTER1" || "$1" == "$CLUSTER2" ]]; then
    region="$1"
  else
    echo "Invalid region specified. Must be one of: $CLUSTER1, $CLUSTER2"
    exit 1
  fi
fi

echo "Using region: $region"

# Helper function to pause
wait_for_user() {
  local nextAction="$1"

  echo ""
  echo "About to:"
  echo "###############################################################################################################"
  echo "$nextAction"
  echo "###############################################################################################################"
  echo "Press Enter to continue..."
  read -rp ""
  echo ""
}

check_rec_health() {
  echo -e "\nChecking Redis Enterprise cluster health..."
  for i in {1..5}; do
    if output=$(kubectl exec -n "$NS" "rec-$region-0" -- rladmin status 2>&1); then
      local unhealthy_count
      unhealthy_count=$(echo "$output" | grep -i "not available\|fail\|error\|down" | wc -l | xargs)
      if [[ "$unhealthy_count" -eq 0 ]]; then
        echo "Redis Enterprise cluster appears healthy (no 'down' or 'fail' reported)"
        return 0
      else
        echo "Redis Enterprise cluster is still recovering..."
        return 1
      fi
    else
      echo "Redis Enterprise cluster is still recovering... ($i/5)"
      sleep 5
    fi
  done

  return 1
}

wait_for_cluster_to_recover(){
  local expected_pod_count="$1"
  local NS="$2"

  echo "##############################################################################################"
  echo "# Waiting for all $expected_pod_count pods in namespace $NS to be in 'Running' state"
  echo "# and for Redis to be healthy..."
  echo "##################################################################################################################"
  until [[ "$(kubectl get pods -n "$NS" --no-headers | wc -l | xargs)" -eq "$expected_pod_count" ]] && \
        ! kubectl get pods -n "$NS" --no-headers | awk '{print $3}' | grep -qv "Running" && \
        check_rec_health; do
    echo -n "."
    sleep 5
  done
  echo ""
  echo "All $expected_pod_count pods are Running and Redis cluster is healthy in namespace $NS"
  echo ""

}

# Reminder to start the Flask app
echo ""
echo "##############################################################################################"
echo "# Please ensure the benchmark application (flask/app.py) is running to observe the impact."
echo "##############################################################################################"
echo ""

echo "Switching context to cluster: $region"
kubectl config use-context "$region"

echo "Nodes in $region:"
echo "#*********************************************************************"
kubectl get nodes
echo "#*********************************************************************"

echo "Fetching VMSS info..."
cluster=$(az vmss list -o table | grep -i "$region" || true)

if [[ -z "$cluster" ]]; then
  echo "No VMSS found for region '$region'. Check if the name matches."
  exit 1
fi
rg=$(echo "$cluster" | awk '{print $2}')
vmss=$(echo "$cluster" | awk '{print $1}')

wait_for_user "Simulating k8s level failure - force delete one of the redis enterprise pods of $region and wait for recovery"

expected_pod_count=$(kubectl get pods -n "$NS" --no-headers | wc -l | xargs)
echo ""
echo "Force deleting Redis Enterprise pod in $region"
kubectl delete pod "rec-$region-0" -n "$NS" --force

wait_for_cluster_to_recover "$expected_pod_count" "$NS"

first_instance_id=$(az vmss list-instances --name "$vmss" --resource-group "$rg" --query "[0].instanceId" -o tsv)

wait_for_user "Restart a virtual machine scale set (underlying infrastructure for a Redis Enterprise Node) VMSS='$vmss', RG='$rg', instance-ids='$first_instance_id'"
#Instance ID is not always 1, if you execute this script twice, it will be 3,4,5 instead of 0,1,2

echo "Restarting a single cluster node in region='$region'"
echo "az vmss restart --name \"$vmss\" --resource-group \"$rg\" --instance-ids \"$first_instance_id\""

az vmss restart --name "$vmss" --resource-group "$rg" --instance-ids "$first_instance_id"

wait_for_cluster_to_recover "$expected_pod_count" "$NS"

wait_for_user "Simulating a region outage by stopping the AKS cluster in region '$region'"

echo "Stopping AKS cluster in $region"
az aks stop --name "$region" --resource-group "$RESOURCE_GROUP"

echo "Waiting for AKS cluster '$region' to fully stop..."
while true; do
  state=$(az aks show --name "$region" --resource-group "$RESOURCE_GROUP" --query "powerState.code" -o tsv 2>/dev/null || echo "Unavailable")
  echo "Current powerState: '$state'"
  if [[ "$state" == "Stopped" ]]; then
    echo "Cluster $region is stopped."
    break
  fi
  echo -n "."
  sleep 5
done

wait_for_user "DO : Test that you can access data from the other region with Redis Insight, before restarting the region"

echo "Restarting AKS cluster in region:'$region', resource-groupe:'$RESOURCE_GROUP' "
az aks start --name "$region" --resource-group "$RESOURCE_GROUP"

echo "Waiting for AKS cluster '$region' to fully Running..."
while true; do
  state=$(az aks show --name "$region" --resource-group "$RESOURCE_GROUP" --query "powerState.code" -o tsv 2>/dev/null || echo "Unavailable")
  echo "Current powerState: '$state'"
  if [[ "$state" == "Running" ]]; then
    echo "Cluster $region is running."
    break
  fi
  sleep 5
done

wait_for_user "Region is back up, now restore the Redis Enterprise Cluster"

echo "Recovering Redis Enterprise Cluster object in $region, after Quorum loss"
kubectl -n "$NS" patch rec "rec-$region" --type merge --patch '{"spec":{"clusterRecovery":true}}'

wait_for_cluster_to_recover "$expected_pod_count" "$NS"

echo ""
echo "#********************************************************************************************  "
echo "# Redis Enterprise Cluster is back up. Wait that all indicators are green before proceeding."
echo "# it takes about 5 minutes to do so, be patient"
echo "# You should see some nodes going from green to red, and finally all green"
echo "#********************************************************************************************  "
wait_for_user "Once it's , press any key to Recover Database after Quorum Loss"

echo "Recovering databases... : rladmin recover all"
kubectl exec -it -n "$NS" "rec-$region-0" -- rladmin recover all

echo "DO : Check that you can access data from both region, and that an update on one region is visible on the other region"