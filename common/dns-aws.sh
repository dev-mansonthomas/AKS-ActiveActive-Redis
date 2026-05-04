#!/usr/bin/env bash
# ============================================================================
# AWS Route53 DNS Management
# ============================================================================
# This script provides DNS management functions for AWS Route53
# Functions:
#   - create_dns_zone()       - Create a Route53 hosted zone
#   - create_dns_record()     - Create A record in Route53
#   - delete_dns_record()     - Delete A record from Route53
#   - list_dns_records()      - List all records in a hosted zone
#   - get_hosted_zone_id()    - Get hosted zone ID by domain name
# ============================================================================

# Get hosted zone ID by domain name
# Usage: get_hosted_zone_id <domain_name>
get_hosted_zone_id() {
  local domain_name="$1"
  
  local zone_id=$(aws route53 list-hosted-zones-by-name \
    --query "HostedZones[?Name=='${domain_name}.'].Id" \
    --output text | cut -d'/' -f3)
  
  echo "$zone_id"
}

# Create a Route53 hosted zone
# Usage: create_dns_zone <domain_name> <owner> <skip_deletion>
create_dns_zone() {
  local domain_name="$1"
  local owner="$2"
  local skip_deletion="${3:-yes}"
  
  echo "🌐 Creating Route53 hosted zone for $domain_name..."
  
  # Check if zone already exists
  local existing_zone=$(get_hosted_zone_id "$domain_name")
  
  if [ -n "$existing_zone" ]; then
    echo "✅ Hosted zone already exists: $existing_zone"
    return 0
  fi
  
  # Create hosted zone
  local caller_reference="redis-$(date +%s)"
  
  aws route53 create-hosted-zone \
    --name "$domain_name" \
    --caller-reference "$caller_reference" \
    --hosted-zone-config "Comment=Redis Enterprise Active/Active DNS,PrivateZone=false" \
    --tags "Key=owner,Value=$owner" "Key=skip_deletion,Value=$skip_deletion"
  
  echo "✅ Hosted zone created for $domain_name"
  echo ""
  echo "⚠️  IMPORTANT: Update your domain registrar with the following nameservers:"
  aws route53 get-hosted-zone --id "$(get_hosted_zone_id "$domain_name")" \
    --query 'DelegationSet.NameServers' --output table
}

# Create DNS A record
# Usage: create_dns_record <domain_name> <record_name> <ip_address> <ttl>
create_dns_record() {
  local domain_name="$1"
  local record_name="$2"
  local ip_address="$3"
  local ttl="${4:-300}"
  
  local zone_id=$(get_hosted_zone_id "$domain_name")
  
  if [ -z "$zone_id" ]; then
    echo "❌ Hosted zone not found for $domain_name"
    return 1
  fi
  
  echo "📝 Creating DNS record: $record_name.$domain_name -> $ip_address"
  
  local change_batch=$(cat <<EOF
{
  "Changes": [{
    "Action": "UPSERT",
    "ResourceRecordSet": {
      "Name": "${record_name}.${domain_name}",
      "Type": "A",
      "TTL": ${ttl},
      "ResourceRecords": [{"Value": "${ip_address}"}]
    }
  }]
}
EOF
)
  
  aws route53 change-resource-record-sets \
    --hosted-zone-id "$zone_id" \
    --change-batch "$change_batch" \
    --output json > /dev/null
  
  echo "✅ DNS record created successfully"
}

# Delete DNS A record
# Usage: delete_dns_record <domain_name> <record_name>
delete_dns_record() {
  local domain_name="$1"
  local record_name="$2"
  
  local zone_id=$(get_hosted_zone_id "$domain_name")
  
  if [ -z "$zone_id" ]; then
    echo "❌ Hosted zone not found for $domain_name"
    return 1
  fi
  
  echo "🗑️  Deleting DNS record: $record_name.$domain_name"
  
  # Get current record to delete
  local current_record=$(aws route53 list-resource-record-sets \
    --hosted-zone-id "$zone_id" \
    --query "ResourceRecordSets[?Name=='${record_name}.${domain_name}.']" \
    --output json)
  
  if [ "$current_record" == "[]" ]; then
    echo "⚠️  Record not found, skipping"
    return 0
  fi
  
  local ip_address=$(echo "$current_record" | jq -r '.[0].ResourceRecords[0].Value')
  local ttl=$(echo "$current_record" | jq -r '.[0].TTL')
  
  local change_batch=$(cat <<EOF
{
  "Changes": [{
    "Action": "DELETE",
    "ResourceRecordSet": {
      "Name": "${record_name}.${domain_name}",
      "Type": "A",
      "TTL": ${ttl},
      "ResourceRecords": [{"Value": "${ip_address}"}]
    }
  }]
}
EOF
)
  
  aws route53 change-resource-record-sets \
    --hosted-zone-id "$zone_id" \
    --change-batch "$change_batch" \
    --output json > /dev/null
  
  echo "✅ DNS record deleted successfully"
}

# List all DNS records in a hosted zone
# Usage: list_dns_records <domain_name>
list_dns_records() {
  local domain_name="$1"
  
  local zone_id=$(get_hosted_zone_id "$domain_name")
  
  if [ -z "$zone_id" ]; then
    echo "❌ Hosted zone not found for $domain_name"
    return 1
  fi
  
  echo "📋 DNS records for $domain_name:"
  aws route53 list-resource-record-sets \
    --hosted-zone-id "$zone_id" \
    --output table
}

# Export functions
export -f get_hosted_zone_id
export -f create_dns_zone
export -f create_dns_record
export -f delete_dns_record
export -f list_dns_records
