#!/bin/bash
source ./config.sh
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