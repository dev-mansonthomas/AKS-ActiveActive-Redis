#!/usr/bin/env bash
# Start total timer
total_start=$(date +%s)

source ./config.sh

TF_VAR_subscription_id=$(az account show --query id -o tsv)
TF_VAR_azure_rg=$RESOURCE_GROUP
export TF_VAR_subscription_id TF_VAR_azure_rg

tofu destroy -auto-approve
echo "Cleaning up Redis-related Kubernetes resources..."

for CLUSTER in $CLUSTER1 $CLUSTER2; do
  echo "⛔ Deleting namespace $NS in cluster $CLUSTER..."
  kubectl delete ns $NS --context=$CLUSTER 2>/dev/null || true

  echo "⛔ Deleting ingress-controller namespace in cluster $CLUSTER..."
  kubectl delete ns ingress-controller --context=$CLUSTER 2>/dev/null || true

  echo "⛔ Forcing Helm uninstall of haproxy-ingress (if still tracked) in $CLUSTER..."
  helm uninstall haproxy-ingress -n ingress-controller --kube-context=$CLUSTER 2>/dev/null || true
done

echo "Cleaning up DNS entries in Azure..."
az network dns record-set a delete -g $DNS_RESOURCE_GROUP -z $DNS_ZONE -n "*.$CLUSTER1" -y 2>/dev/null || true
az network dns record-set a delete -g $DNS_RESOURCE_GROUP -z $DNS_ZONE -n "*.$CLUSTER2" -y 2>/dev/null || true

echo "Cleanup complete."

# End total timer
total_end=$(date +%s)
total_duration=$(( (total_end - total_start) / 60 ))

echo "========================================="
echo "⏱️ Total execution time: ${total_duration} minutes"
echo "========================================="