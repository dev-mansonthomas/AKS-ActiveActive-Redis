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
echo -e "${YELLOW}3. Checking network resources (by NAME — GCP cannot label these)${NC}"
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "  ${BLUE}Note:${NC} google_compute_{network,subnetwork,firewall} and"
echo -e "        google_container_node_pool do NOT support labels in GCP, so"
echo -e "        ownership can only be asserted from the CLUSTER_PREFIX naming"
echo -e "        convention. See docs/adr/0006. This is why a unique prefix"
echo -e "        matters on a shared project."
echo ""

# re_gcp_exists <描述> <gcloud args...> -> echoes the name if it exists
_check_by_name() {
  local kind="$1" name="$2"; shift 2
  local found
  found=$("$@" 2>/dev/null)
  TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
  if [ -n "$found" ]; then
    if [ "${name#"${CLUSTER_PREFIX}"}" != "$name" ]; then
      echo -e "  ${GREEN}✓${NC} $kind '$name' exists and carries the '${CLUSTER_PREFIX}' prefix"
      PASSED_CHECKS=$((PASSED_CHECKS + 1))
    else
      echo -e "  ${RED}✗${NC} $kind '$name' exists but does NOT start with '${CLUSTER_PREFIX}'"
      echo -e "    it is not attributable to this rig — another operator may own it"
      FAILED_CHECKS=$((FAILED_CHECKS + 1))
    fi
  else
    echo -e "  ${YELLOW}⚠${NC} $kind '$name' not found (not created, or already destroyed)"
    TOTAL_CHECKS=$((TOTAL_CHECKS - 1))
  fi
}

echo -e "${BLUE}VPC network:${NC}"
_check_by_name "VPC network" "${CLUSTER_PREFIX}-vpc" \
  gcloud compute networks describe "${CLUSTER_PREFIX}-vpc" \
    --project="$GCP_PROJECT_ID" --format="value(name)"
echo ""

echo -e "${BLUE}Subnets:${NC}"
for _region in "$GCP_REGION1" "$GCP_REGION2"; do
  _subnet="${CLUSTER_PREFIX}-subnet-${_region}"
  _check_by_name "Subnet" "$_subnet" \
    gcloud compute networks subnets describe "$_subnet" \
      --region="$_region" --project="$GCP_PROJECT_ID" --format="value(name)"
done
echo ""

echo -e "${BLUE}Firewall rules:${NC}"
for _fw in "${CLUSTER_PREFIX}-allow-internal" "${CLUSTER_PREFIX}-allow-redis-ports"; do
  _check_by_name "Firewall rule" "$_fw" \
    gcloud compute firewall-rules describe "$_fw" \
      --project="$GCP_PROJECT_ID" --format="value(name)"
done
echo ""

echo -e "${BLUE}Node pools:${NC}"
for _pair in "$CLUSTER1:$GCP_REGION1" "$CLUSTER2:$GCP_REGION2"; do
  _cl="${_pair%%:*}"; _rg="${_pair##*:}"
  _np="${_cl}-nodes"
  _check_by_name "Node pool" "$_np" \
    gcloud container node-pools describe "$_np" \
      --cluster="$_cl" --region="$_rg" --project="$GCP_PROJECT_ID" --format="value(name)"
done
echo ""

echo -e "${BLUE}Anything in this project carrying our prefix but unexpected:${NC}"
_stray=$(gcloud compute networks list --project="$GCP_PROJECT_ID" \
  --filter="name~^${CLUSTER_PREFIX}" --format="value(name)" 2>/dev/null)
if [ -n "$_stray" ]; then
  printf '%s\n' "$_stray" | while IFS= read -r _n; do
    [ "$_n" = "${CLUSTER_PREFIX}-vpc" ] || echo -e "  ${YELLOW}⚠ unexpected network: $_n${NC}"
  done
fi
echo ""

echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${YELLOW}4. Summary - All Resources by Label${NC}"
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

echo -e "${BLUE}Resources labeled owner=$owner whose name carries this rig's prefix (${CLUSTER_PREFIX}):${NC}"
echo -e "  (informational: Cloud Asset lags a few minutes — a just-deleted node pool can still show as STOPPING;"
echo -e "   the name-based checks above are the verdict. Other projects' resources of the same owner are filtered out.)"
gcloud asset search-all-resources \
  --scope="projects/${GCP_PROJECT_ID}" \
  --query="labels.owner=${owner} AND name:${CLUSTER_PREFIX}" \
  --format="table(name.basename(),assetType.basename(),location,state)" \
  || echo -e "  ${YELLOW}⚠ asset search failed (needs cloudasset API + roles/cloudasset.viewer — see docs/gcp-iam.md)${NC}"
echo ""
