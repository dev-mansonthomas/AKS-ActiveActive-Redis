#!/usr/bin/env bash
# ============================================================================
# GCP Cloud DNS Management
# ============================================================================
# This script provides DNS management functions for GCP Cloud DNS
# Functions:
#   - create_dns_zone()       - Create a Cloud DNS managed zone
#   - create_dns_record()     - Create A record in Cloud DNS
#   - delete_dns_record()     - Delete A record from Cloud DNS
#   - list_dns_records()      - List all records in a managed zone
#   - get_dns_zone()          - Get managed zone by domain name
# ============================================================================

# Get managed zone name by domain
# Usage: get_dns_zone <domain_name> <project_id>
get_dns_zone() {
  local domain_name="$1"
  local project_id="$2"
  
  # Cloud DNS zone names cannot contain dots, so we replace them with dashes
  local zone_name=$(echo "$domain_name" | tr '.' '-')
  
  # Check if zone exists
  if gcloud dns managed-zones describe "$zone_name" --project="$project_id" &>/dev/null; then
    echo "$zone_name"
  else
    echo ""
  fi
}

# Create a Cloud DNS managed zone
# Usage: create_dns_zone <domain_name> <project_id> <owner> <skip_deletion>
create_dns_zone() {
  local domain_name="$1"
  local project_id="$2"
  local owner="$3"
  local skip_deletion="${4:-yes}"
  
  echo "🌐 Creating Cloud DNS managed zone for $domain_name..."
  
  # Cloud DNS zone name (replace dots with dashes)
  local zone_name=$(echo "$domain_name" | tr '.' '-')
  
  # Check if zone already exists
  if [ -n "$(get_dns_zone "$domain_name" "$project_id")" ]; then
    echo "✅ Managed zone already exists: $zone_name"
    return 0
  fi
  
  # Create managed zone
  gcloud dns managed-zones create "$zone_name" \
    --project="$project_id" \
    --dns-name="${domain_name}." \
    --description="Redis Enterprise Active/Active DNS Zone" \
    --labels="owner=${owner},skip_deletion=${skip_deletion}" \
    --visibility=public
  
  echo "✅ Managed zone created: $zone_name"
  echo ""
  echo "⚠️  IMPORTANT: Update your domain registrar with the following nameservers:"
  gcloud dns managed-zones describe "$zone_name" \
    --project="$project_id" \
    --format="value(nameServers)"
}

# Create or update a DNS A record (idempotent).
# Usage: create_dns_record <domain_name> <project_id> <record_name> <ip_address> <ttl>
# Uses `record-sets create|update` rather than a transaction: a transaction
# writes transaction.yaml into the cwd, cannot replace a record that holds a
# DIFFERENT ip, and a failed run leaves the file behind to break the next one.
create_dns_record() {
  local domain_name="$1"
  local project_id="$2"
  local record_name="$3"
  local ip_address="$4"
  local ttl="${5:-300}"

  local zone_name
  zone_name=$(get_dns_zone "$domain_name" "$project_id")

  if [ -z "$zone_name" ]; then
    echo "❌ Managed zone not found for $domain_name"
    return 1
  fi

  local fqdn="${record_name}.${domain_name}."
  local verb="create" existing
  existing=$(gcloud dns record-sets list --zone="$zone_name" --project="$project_id" \
    --name="$fqdn" --type=A --format="value(rrdatas[0])" 2>/dev/null)
  [ -n "$existing" ] && verb="update"

  echo "📝 DNS record ($verb): ${fqdn} -> $ip_address"
  gcloud dns record-sets "$verb" "$fqdn" \
    --zone="$zone_name" --project="$project_id" \
    --type=A --ttl="$ttl" --rrdatas="$ip_address" || return 1

  echo "✅ DNS record ${verb}d successfully"
}

# Delete DNS A record (a missing record is not an error).
# Usage: delete_dns_record <domain_name> <project_id> <record_name>
delete_dns_record() {
  local domain_name="$1"
  local project_id="$2"
  local record_name="$3"

  local zone_name
  zone_name=$(get_dns_zone "$domain_name" "$project_id")

  if [ -z "$zone_name" ]; then
    echo "❌ Managed zone not found for $domain_name"
    return 1
  fi

  local fqdn="${record_name}.${domain_name}."
  echo "🗑️  Deleting DNS record: ${fqdn}"

  if [ -z "$(gcloud dns record-sets list --zone="$zone_name" --project="$project_id" \
        --name="$fqdn" --type=A --format="value(name)" 2>/dev/null)" ]; then
    echo "⚠️  Record not found, skipping"
    return 0
  fi

  gcloud dns record-sets delete "$fqdn" \
    --zone="$zone_name" --project="$project_id" --type=A || return 1

  echo "✅ DNS record deleted successfully"
}

# List all DNS records in a managed zone
# Usage: list_dns_records <domain_name> <project_id>
list_dns_records() {
  local domain_name="$1"
  local project_id="$2"
  
  local zone_name=$(get_dns_zone "$domain_name" "$project_id")
  
  if [ -z "$zone_name" ]; then
    echo "❌ Managed zone not found for $domain_name"
    return 1
  fi
  
  echo "📋 DNS records for $domain_name:"
  gcloud dns record-sets list \
    --zone="$zone_name" \
    --project="$project_id"
}

# Export functions
export -f get_dns_zone
export -f create_dns_zone
export -f create_dns_record
export -f delete_dns_record
export -f list_dns_records
