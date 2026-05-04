#!/usr/bin/env bash
# ============================================================================
# Create All - Multi-Cloud Redis Enterprise Active/Active Deployment
# ============================================================================
# This script orchestrates the full deployment process
# Supports: Azure (AKS), AWS (EKS), GCP (GKE)
# ============================================================================

set -e

# Load configuration
source ../config.sh

echo "🚀 Starting Redis Enterprise Active/Active deployment on $CLOUD_PROVIDER"
echo "========================================================================="

declare -A durations  # Stocke durée par script en secondes
declare -a scripts    # Stocke l'ordre d'exécution

measure_time() {
  local script="$1"
  local start_time=$(date +%s)

  echo ""
  echo "🚀 Starting $script..."
  echo "========================================================================="
  ./"$script"

  local end_time=$(date +%s)
  local duration=$((end_time - start_time))  # Garde en secondes

  durations["$script"]=$duration
  scripts+=("$script")
}


# Exécution des scripts
measure_time "01-create-cluster.sh"
measure_time "02-setup-haproxy.sh"
measure_time "03-setup-rerc.sh"
measure_time "04-create-active-active-db.sh"

# Résumé propre
echo ""
echo "========================================="
echo "⏱️ Execution Summary:"
total_duration=0
for script in "${scripts[@]}"; do
  duration=${durations[$script]}
  minutes=$((duration / 60))
  seconds=$((duration % 60))
  printf "• %-30s : %2d min %02d sec\n" "$script" "$minutes" "$seconds"
  total_duration=$((total_duration + duration))
done
echo "-----------------------------------------"
total_minutes=$((total_duration / 60))
total_seconds=$((total_duration % 60))
printf "🔴 Total execution time         : %2d min %02d sec\n" "$total_minutes" "$total_seconds"
echo "========================================="

echo "Waiting 5 seconds - otherwise some info are missing"
sleep 5

./05-get-cluster-info.sh