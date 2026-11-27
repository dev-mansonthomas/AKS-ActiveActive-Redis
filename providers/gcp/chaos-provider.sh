#!/usr/bin/env bash
# ============================================================================
# GCP GKE - Chaos Engineering Functions
# ============================================================================
# This script provides chaos engineering capabilities for GCP GKE
# Functions:
#   - restart_node()    - Delete a GCE instance (managed instance group recreates)
#   - stop_cluster()    - Simulate cluster failure by cordoning all nodes
#   - start_cluster()   - Uncordon all nodes
#   - get_node_info()   - Get information about GKE nodes
#   - resize_cluster()  - Temporarily resize cluster to simulate failure
# ============================================================================

# Restart a random node in the specified cluster
# Usage: restart_node <cluster_name> <region> <project_id>
restart_node() {
  local cluster_name="$1"
  local region="$2"
  local project_id="$3"
  
  echo "🔥 Restarting random node in cluster $cluster_name (region: $region)..."
  
  # Get a random node
  local node=$(kubectl get nodes --context="$cluster_name" -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | shuf | head -n 1)
  
  if [ -z "$node" ]; then
    echo "❌ No nodes found in cluster $cluster_name"
    return 1
  fi
  
  echo "📍 Selected node: $node"
  
  # Get the instance name (GKE nodes are named like: gke-cluster-name-pool-name-hash)
  # The GCE instance name is typically the same as the node name
  local instance_name="$node"
  
  # Get the zone from the node
  local zone=$(kubectl get node "$node" --context="$cluster_name" -o jsonpath='{.metadata.labels.topology\.kubernetes\.io/zone}')
  
  if [ -z "$zone" ]; then
    # Fallback: try to find the zone from gcloud
    zone=$(gcloud compute instances list --project="$project_id" --filter="name=$instance_name" --format="value(zone)" | head -n 1)
  fi
  
  if [ -z "$zone" ]; then
    echo "❌ Could not determine zone for node $node"
    return 1
  fi
  
  echo "🔧 Deleting GCE instance: $instance_name in zone $zone"
  gcloud compute instances delete "$instance_name" \
    --zone="$zone" \
    --project="$project_id" \
    --quiet
  
  echo "✅ Instance $instance_name deleted. Managed instance group will launch a replacement."
  echo "⏳ This may take 2-5 minutes..."
}

# Stop cluster (cordon all nodes to simulate failure)
# Usage: stop_cluster <cluster_name>
stop_cluster() {
  local cluster_name="$1"
  
  echo "⛔ Stopping cluster $cluster_name (cordoning all nodes)..."
  
  kubectl get nodes --context="$cluster_name" -o name | while read -r node; do
    kubectl cordon "$node" --context="$cluster_name"
  done
  
  echo "✅ All nodes in $cluster_name are cordoned (no new pods will be scheduled)"
}

# Start cluster (uncordon all nodes)
# Usage: start_cluster <cluster_name>
start_cluster() {
  local cluster_name="$1"
  
  echo "✅ Starting cluster $cluster_name (uncordoning all nodes)..."
  
  kubectl get nodes --context="$cluster_name" -o name | while read -r node; do
    kubectl uncordon "$node" --context="$cluster_name"
  done
  
  echo "✅ All nodes in $cluster_name are ready to schedule pods"
}

# Get node information
# Usage: get_node_info <cluster_name> <region> <project_id>
get_node_info() {
  local cluster_name="$1"
  local region="$2"
  local project_id="$3"
  
  echo "📊 Node information for cluster $cluster_name:"
  echo ""
  
  kubectl get nodes --context="$cluster_name" -o wide
  
  echo ""
  echo "GCE Instances in region $region:"
  gcloud compute instances list \
    --project="$project_id" \
    --filter="name~^gke-$cluster_name" \
    --format="table(name,machineType.basename(),zone.basename(),status,networkInterfaces[0].networkIP)"
}

# Drain a specific node (gracefully evict all pods)
# Usage: drain_node <cluster_name> <node_name>
drain_node() {
  local cluster_name="$1"
  local node_name="$2"
  
  echo "🌊 Draining node $node_name in cluster $cluster_name..."
  
  kubectl drain "$node_name" \
    --context="$cluster_name" \
    --ignore-daemonsets \
    --delete-emptydir-data \
    --force \
    --grace-period=30
  
  echo "✅ Node $node_name drained"
}

# Resize node pool (simulate failure by scaling down)
# Usage: resize_cluster <cluster_name> <region> <project_id> <node_count>
resize_cluster() {
  local cluster_name="$1"
  local region="$2"
  local project_id="$3"
  local node_count="$4"
  
  echo "📏 Resizing cluster $cluster_name to $node_count nodes..."
  
  # Get node pool name (assumes single node pool named after cluster)
  local node_pool="${cluster_name}-nodes"
  
  gcloud container clusters resize "$cluster_name" \
    --node-pool="$node_pool" \
    --num-nodes="$node_count" \
    --region="$region" \
    --project="$project_id" \
    --quiet
  
  echo "✅ Cluster $cluster_name resized to $node_count nodes"
}

# Export functions for use in other scripts
export -f restart_node
export -f stop_cluster
export -f start_cluster
export -f get_node_info
export -f drain_node
export -f resize_cluster
