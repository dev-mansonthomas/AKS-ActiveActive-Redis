#!/usr/bin/env bash
#!/usr/bin/env bash

###############################################################################
# Redis Enterprise - AKS Active-Active Chaos Testing Script
#
# This script simulates failure and recovery scenarios for a Redis Enterprise
# deployment running in Active-Active mode on Azure Kubernetes Service (AKS).
#
# It allows the operator to:
#  - Select a region where the chaos scenario will be applied
#  - Observe Redis cluster behavior during node failure and AKS restarts
#  - Demonstrate Redis Enterprise resilience and automated recovery
#
# Prerequisites:
#  - Azure CLI authenticated and context properly set
#  - config.sh file sourcing variables: CLUSTER1, CLUSTER2, CLUSTER3, NS, etc.
#  - Flask benchmark app (`flask/app.py`) should be running to visualize impact
#
# Steps performed:
#  1. Prompt operator to choose target region
#  2. Remind to launch benchmark application
#  3. Switch `kubectl` context to the selected region's AKS cluster
#  4. Display AKS node info
#  5. Find corresponding VMSS name and resource group using `az vmss list`
#  6. Record expected pod count in namespace `$NS`
#  7. Force delete a Redis pod (`rec-<region>-0`) to simulate a failure
#  8. Restart one VMSS instance (ID 1) via Azure CLI
#  9. Wait until all expected pods in the namespace are back in "Running" state
# 10. Stop then restart the AKS cluster to simulate a full cluster downtime
# 11. Trigger Redis Enterprise cluster object recovery using REC patch
# 12. Watch for REC object state progression
# 13. Trigger full database recovery using `rladmin recover all`
#
# Usage:
#   ./chaos.sh
#
###############################################################################
set -euo pipefail

# Load configuration
. ./config.sh

# Ask the operator for the region to use
echo "Available regions: $CLUSTER1 $CLUSTER2 $CLUSTER3"
read -rp "➡️  Enter the region to test (e.g., $CLUSTER1): " region
region=${region:-$CLUSTER1}

echo "✅ Using region: $region"

# Helper function to pause
wait_for_user() {
  read -rp "⏸️  Press Enter to continue..."
}

# Reminder to start the Flask app
echo "🚀 Please ensure the benchmark application (flask/app.py) is running to observe the impact."
wait_for_user

echo "🔁 Switching context to cluster: $region"
kubectl config use-context "$region"

echo "🔎 Nodes in $region:"
kubectl get nodes

echo "💬 Fetching VMSS info..."
cluster=$(az vmss list -o table | grep -i "$region" || true)

if [[ -z "$cluster" ]]; then
  echo "❌ No VMSS found for region '$region'. Check if the name matches."
  exit 1
fi
rg=$(echo "$cluster" | awk '{print $2}')
vmss=$(echo "$cluster" | awk '{print $1}')

wait_for_user

expected_pod_count=$(kubectl get pods -n "$NS" --no-headers | wc -l)

echo "🔥 Force deleting Redis Enterprise pod in $region"
kubectl delete pod "rec-$region-0" -n "$NS" --force
wait_for_user

echo "🔁 Restarting a single cluster node in $region"
az vmss restart --name "$vmss" --resource-group "$rg" --instance-ids 1 --no-wait
echo "🔍 Monitoring pod restart..."
echo "⏳ Waiting for all $expected_pod_count pods in namespace $NS to be in 'Running' state..."
until [[ "$(kubectl get pods -n "$NS" --no-headers | wc -l)" -eq "$expected_pod_count" ]] && \
      kubectl get pods -n "$NS" --no-headers | awk '{print $3}' | grep -v "Running" | grep -qv .; do
  sleep 5
done

echo "✅ All $expected_pod_count pods are Running in namespace $NS"
wait_for_user

echo "🛑 Stopping AKS cluster in $region"
az aks stop --name "$region" --resource-group "$RESOURCE_GROUP" --no-wait
sleep 30
echo "▶️ Restarting AKS cluster in $region"
az aks start --name "$region" --resource-group "$RESOURCE_GROUP" --no-wait
wait_for_user

echo "🩹 Recovering Redis Enterprise Cluster object in $region"
kubectl -n "$NS" patch rec "rec-$region" --type merge --patch '{"spec":{"clusterRecovery":true}}'
watch "kubectl -n $NS describe rec | grep State"
wait_for_user

echo "🧠 Recovering databases..."
kubectl exec -it -n "$NS" "rec-$region-0" -- rladmin recover all
