#!/usr/bin/env bash
# ============================================================================
# AWS EKS - Chaos Engineering Functions
# ============================================================================
# This script provides chaos engineering capabilities for AWS EKS
# Functions:
#   - restart_node()    - Terminate an EC2 instance (ASG will recreate)
#   - stop_cluster()    - Simulate cluster failure by cordoning all nodes
#   - start_cluster()   - Uncordon all nodes
#   - get_node_info()   - Get information about EKS nodes
# ============================================================================

# Restart a random node in the specified cluster
# Usage: restart_node <cluster_name> <region>
restart_node() {
  local cluster_name="$1"
  local region="$2"
  
  echo "🔥 Restarting random node in cluster $cluster_name (region: $region)..."
  
  # Get a random node
  local node=$(kubectl get nodes --context="$cluster_name" -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | shuf | head -n 1)
  
  if [ -z "$node" ]; then
    echo "❌ No nodes found in cluster $cluster_name"
    return 1
  fi
  
  echo "📍 Selected node: $node"
  
  # Get the EC2 instance ID from the node
  local instance_id=$(kubectl get node "$node" --context="$cluster_name" -o jsonpath='{.spec.providerID}' | cut -d'/' -f5)
  
  if [ -z "$instance_id" ]; then
    echo "❌ Could not find instance ID for node $node"
    return 1
  fi
  
  echo "🔧 Terminating EC2 instance: $instance_id"
  aws ec2 terminate-instances --instance-ids "$instance_id" --region "$region"
  
  echo "✅ Instance $instance_id terminated. ASG will launch a replacement."
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
# Usage: get_node_info <cluster_name> <region>
get_node_info() {
  local cluster_name="$1"
  local region="$2"
  
  echo "📊 Node information for cluster $cluster_name:"
  echo ""
  
  kubectl get nodes --context="$cluster_name" -o wide
  
  echo ""
  echo "EC2 Instances in region $region:"
  aws ec2 describe-instances \
    --region "$region" \
    --filters "Name=tag:kubernetes.io/cluster/$cluster_name,Values=owned" \
    --query 'Reservations[*].Instances[*].[InstanceId,InstanceType,State.Name,PrivateIpAddress]' \
    --output table
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

# Export functions for use in other scripts
export -f restart_node
export -f stop_cluster
export -f start_cluster
export -f get_node_info
export -f drain_node
