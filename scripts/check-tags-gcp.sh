#!/usr/bin/env bash
# ============================================================================
# GCP Resource Labels Verification
# ============================================================================
# Note: GCP uses "labels" instead of "tags"
# ============================================================================

echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${YELLOW}1. Checking GKE Clusters - Region 1${NC}"
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# Check GKE cluster in region 1
echo -e "${BLUE}Checking:${NC} GKE Cluster '$CLUSTER1' (region: $GCP_REGION1)"

cluster1_labels=$(gcloud container clusters describe "$CLUSTER1" \
  --region="$GCP_REGION1" \
  --project="$GCP_PROJECT_ID" \
  --format="json(resourceLabels)" 2>/dev/null)

if [ -n "$cluster1_labels" ] && [ "$cluster1_labels" != "null" ]; then
  TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
  
  # Check owner label
  owner_label=$(echo "$cluster1_labels" | jq -r '.resourceLabels.owner // empty')
  if [ "$owner_label" == "$owner" ]; then
    echo -e "  ${GREEN}✓ owner = $owner_label${NC}"
  else
    echo -e "  ${RED}✗ owner label missing or incorrect (expected: $owner, found: $owner_label)${NC}"
    FAILED_CHECKS=$((FAILED_CHECKS + 1))
  fi
  
  # Check skip_deletion label
  skip_deletion_label=$(echo "$cluster1_labels" | jq -r '.resourceLabels.skip_deletion // empty')
  if [ "$skip_deletion_label" == "$skip_deletion" ]; then
    echo -e "  ${GREEN}✓ skip_deletion = $skip_deletion_label${NC}"
    PASSED_CHECKS=$((PASSED_CHECKS + 1))
  else
    echo -e "  ${RED}✗ skip_deletion label missing or incorrect (expected: $skip_deletion, found: $skip_deletion_label)${NC}"
    FAILED_CHECKS=$((FAILED_CHECKS + 1))
  fi
else
  echo -e "${YELLOW}⚠ GKE cluster '$CLUSTER1' not found in region $GCP_REGION1 (may not be created yet)${NC}"
fi
echo ""

echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${YELLOW}2. Checking GKE Clusters - Region 2${NC}"
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# Check GKE cluster in region 2
echo -e "${BLUE}Checking:${NC} GKE Cluster '$CLUSTER2' (region: $GCP_REGION2)"

cluster2_labels=$(gcloud container clusters describe "$CLUSTER2" \
  --region="$GCP_REGION2" \
  --project="$GCP_PROJECT_ID" \
  --format="json(resourceLabels)" 2>/dev/null)

if [ -n "$cluster2_labels" ] && [ "$cluster2_labels" != "null" ]; then
  TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
  
  # Check owner label
  owner_label=$(echo "$cluster2_labels" | jq -r '.resourceLabels.owner // empty')
  if [ "$owner_label" == "$owner" ]; then
    echo -e "  ${GREEN}✓ owner = $owner_label${NC}"
  else
    echo -e "  ${RED}✗ owner label missing or incorrect (expected: $owner, found: $owner_label)${NC}"
    FAILED_CHECKS=$((FAILED_CHECKS + 1))
  fi
  
  # Check skip_deletion label
  skip_deletion_label=$(echo "$cluster2_labels" | jq -r '.resourceLabels.skip_deletion // empty')
  if [ "$skip_deletion_label" == "$skip_deletion" ]; then
    echo -e "  ${GREEN}✓ skip_deletion = $skip_deletion_label${NC}"
    PASSED_CHECKS=$((PASSED_CHECKS + 1))
  else
    echo -e "  ${RED}✗ skip_deletion label missing or incorrect (expected: $skip_deletion, found: $skip_deletion_label)${NC}"
    FAILED_CHECKS=$((FAILED_CHECKS + 1))
  fi
else
  echo -e "${YELLOW}⚠ GKE cluster '$CLUSTER2' not found in region $GCP_REGION2 (may not be created yet)${NC}"
fi
echo ""

echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${YELLOW}3. Checking VPC Network${NC}"
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

echo -e "${BLUE}Checking:${NC} VPC Network 'redis-vpc'"

vpc_labels=$(gcloud compute networks describe redis-vpc \
  --project="$GCP_PROJECT_ID" \
  --format="json(labels)" 2>/dev/null)

if [ -n "$vpc_labels" ] && [ "$vpc_labels" != "null" ]; then
  TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
  
  # Check owner label
  owner_label=$(echo "$vpc_labels" | jq -r '.labels.owner // empty')
  if [ "$owner_label" == "$owner" ]; then
    echo -e "  ${GREEN}✓ owner = $owner_label${NC}"
    PASSED_CHECKS=$((PASSED_CHECKS + 1))
  else
    echo -e "  ${RED}✗ owner label missing or incorrect (expected: $owner, found: $owner_label)${NC}"
    FAILED_CHECKS=$((FAILED_CHECKS + 1))
  fi
else
  echo -e "${YELLOW}⚠ VPC Network 'redis-vpc' not found (may not be created yet)${NC}"
fi
echo ""

echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${YELLOW}4. Summary - All Resources by Label${NC}"
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

echo -e "${BLUE}All GCP resources labeled with owner=$owner:${NC}"
gcloud asset search-all-resources \
  --scope="projects/${GCP_PROJECT_ID}" \
  --query="labels.owner=${owner}" \
  --format="table(name,assetType,location)" 2>/dev/null || echo "No resources found (gcloud asset search may not be enabled)"
echo ""
