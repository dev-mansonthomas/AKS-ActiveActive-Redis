#!/usr/bin/env bash
########################################################################################################################
#This scripts configures Ingress controller, Redis Enterprise Operator, Redis Webhook and creates Redis Enterprise
# Cluster in `rec` namespace.
#
#It would also load kubect cluster definitions into the kubectl kubeconfig file, so you can access both participating
# clusters.
########################################################################################################################

# load configuration options from file
# change setting like cluster names, DNS zones etc in config.sh
. config.sh

wait_until() {
  local cmd="$1"
  local max_attempts="$2"
  local sleep_seconds="$3"
  local message="$4"

  echo "⏳ $message"
  echo "🔧 Executing: $cmd"
  local attempt=0
  until eval "$cmd"; do
    if [ $attempt -ge $max_attempts ]; then
      echo "❌ Timeout: $message"
      return 1
    fi
    echo "Still waiting... ($((attempt+1))/$max_attempts)"
    sleep "$sleep_seconds"
    attempt=$((attempt+1))
  done
  echo "✅ $message"
  return 0
}

echo "Using configuration in config.sh:"
cat config.sh

# get defined clusters in kube config
kubectl config get-clusters

# make sure helm repo fot HAProxy is present
# https://haproxy-ingress.github.io/docs/getting-started/
helm repo add haproxy-ingress https://haproxy-ingress.github.io/charts
helm repo update

# get defined clusters in kube config
az aks get-credentials -g $RESOURCE_GROUP  --name $CLUSTER1 --context $CLUSTER1 --overwrite-existing
az aks get-credentials -g $RESOURCE_GROUP  --name $CLUSTER2 --context $CLUSTER2 --overwrite-existing

# cleaning up ./yaml directory
rm ./yaml/*.yaml

for CLUSTER in $CLUSTER1 $CLUSTER2
do

  echo "switching to $CLUSTER"
  kubectl config use-context $CLUSTER
  kubectl create ns $NS

  # install ingress controller
  helm install haproxy-ingress haproxy-ingress/haproxy-ingress\
    --create-namespace --namespace ingress-controller\
    --version 0.14.4\
    -f templates/haproxy-ingress-values.yaml

  # Install Redis operator
  kubectl apply -n $NS -f https://raw.githubusercontent.com/RedisLabs/redis-enterprise-k8s-docs/master/bundle.yaml

  wait_until "kubectl -n \$NS get secret admission-tls >/dev/null 2>&1" 12 5 "Waiting for admission-tls secret in \$CLUSTER"

  CERT=$(kubectl -n $NS get secret admission-tls -o jsonpath='{.data.cert}')


  # Wait until RedisEnterpriseCluster CRD is registered
  echo "Waiting for RedisEnterpriseCluster CRD to become available..."
  CRD_NAME="redisenterpriseclusters.app.redislabs.com"
  wait_until "kubectl get crd \$CRD_NAME >/dev/null 2>&1" 12 5 "Waiting for RedisEnterpriseCluster CRD to become available"

  echo "✅ CRD $CRD_NAME is now available."

  # Create Redis Enterprise Cluster form template in templates folder
  sed -e "s/DNS_ZONE/$DNS_ZONE/g"  \
      -e "s/CLUSTER/$CLUSTER/g"    \
      templates/rec.yaml > yaml/rec-$CLUSTER.yaml

  # Apply RedisEnterpriseCluster spec
  kubectl apply -n $NS -f yaml/rec-$CLUSTER.yaml

  # Wait for REC creation
  REC_NAME="rec-$CLUSTER"
  wait_until "kubectl get rec \$REC_NAME -n \$NS >/dev/null 2>&1" 12 5 "Waiting for RedisEnterpriseCluster \$REC_NAME to appear"

  echo "✅ RedisEnterpriseCluster $REC_NAME found."

  #get public IP of ingress controller

  # Wait for HAProxy ingress public IP
  echo "⏳ Waiting for HAProxy ingress public IP for $CLUSTER..."
  CLUSTER_IP=""
  wait_until "[ -n \"\$(kubectl get svc -n ingress-controller haproxy-ingress -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)\" ]" 12 5 "Waiting for HAProxy ingress public IP for \$CLUSTER"
  CLUSTER_IP=$(kubectl get svc -n ingress-controller haproxy-ingress -o jsonpath="{.status.loadBalancer.ingress[0].ip}")

  # delete existing DNS records if any
  az network dns record-set a delete -g $DNS_RESOURCE_GROUP -z $DNS_ZONE -n "*.$CLUSTER" -y

  # create A record
  # TTL set very low for debug create/destroy cycle. can be omitted (default 3600) in prod
  az network dns record-set a add-record -g $DNS_RESOURCE_GROUP -z $DNS_ZONE -n "*.$CLUSTER" -a $CLUSTER_IP #--ttl 10

  sed -e "s/NAMESPACE/$NS/g" \
      -e "s/CERT/$CERT/g"    \
      templates/webhook.yaml > yaml/webhook-$CLUSTER.yaml

  kubectl -n $NS apply -f yaml/webhook-$CLUSTER.yaml

done

# Set the desired status
desired_status="Running"

# Loop until the desired status is reached
for CLUSTER in $CLUSTER1 $CLUSTER2; do
  REC_NAME="rec-$CLUSTER"
  echo "Checking REC status for $REC_NAME..."
  wait_until "[ \"\$(kubectl get rec $REC_NAME -n $NS --context=$CLUSTER -o json | jq -r .status.state 2>/dev/null)\" = \"$desired_status\" ]" 48 10 "REC $REC_NAME status to reach $desired_status"
done

echo "Status is now $desired_status"
#exit 0
