#!/usr/bin/env bash
# ============================================================================
# AWS Resource Tags Verification
# ============================================================================

echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${YELLOW}1. Checking EKS Clusters - Region 1${NC}"
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# Check EKS cluster in region 1
cluster1_arn=$(aws eks describe-cluster --name "$CLUSTER1" --region "$AWS_REGION1" --query 'cluster.arn' --output text 2>/dev/null)
if [ -n "$cluster1_arn" ] && [ "$cluster1_arn" != "None" ]; then
    check_tags_aws "$cluster1_arn" "EKS Cluster" "$AWS_REGION1"
else
    echo -e "${YELLOW}⚠ EKS cluster '$CLUSTER1' not found in region $AWS_REGION1 (may not be created yet)${NC}"
    echo ""
fi

echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${YELLOW}2. Checking EKS Clusters - Region 2${NC}"
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# Check EKS cluster in region 2
cluster2_arn=$(aws eks describe-cluster --name "$CLUSTER2" --region "$AWS_REGION2" --query 'cluster.arn' --output text 2>/dev/null)
if [ -n "$cluster2_arn" ] && [ "$cluster2_arn" != "None" ]; then
    check_tags_aws "$cluster2_arn" "EKS Cluster" "$AWS_REGION2"
else
    echo -e "${YELLOW}⚠ EKS cluster '$CLUSTER2' not found in region $AWS_REGION2 (may not be created yet)${NC}"
    echo ""
fi

echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${YELLOW}3. Checking VPCs${NC}"
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# Check VPC in region 1
vpc1_id=$(aws ec2 describe-vpcs \
    --region "$AWS_REGION1" \
    --filters "Name=tag:Name,Values=redis-vpc-${AWS_REGION1}" \
    --query 'Vpcs[0].VpcId' --output text 2>/dev/null)

if [ -n "$vpc1_id" ] && [ "$vpc1_id" != "None" ]; then
    vpc1_arn="arn:aws:ec2:${AWS_REGION1}:$(aws sts get-caller-identity --query Account --output text):vpc/${vpc1_id}"
    check_tags_aws "$vpc1_arn" "VPC (Region 1)" "$AWS_REGION1"
else
    echo -e "${YELLOW}⚠ VPC for region $AWS_REGION1 not found (may not be created yet)${NC}"
    echo ""
fi

# Check VPC in region 2
vpc2_id=$(aws ec2 describe-vpcs \
    --region "$AWS_REGION2" \
    --filters "Name=tag:Name,Values=redis-vpc-${AWS_REGION2}" \
    --query 'Vpcs[0].VpcId' --output text 2>/dev/null)

if [ -n "$vpc2_id" ] && [ "$vpc2_id" != "None" ]; then
    vpc2_arn="arn:aws:ec2:${AWS_REGION2}:$(aws sts get-caller-identity --query Account --output text):vpc/${vpc2_id}"
    check_tags_aws "$vpc2_arn" "VPC (Region 2)" "$AWS_REGION2"
else
    echo -e "${YELLOW}⚠ VPC for region $AWS_REGION2 not found (may not be created yet)${NC}"
    echo ""
fi

echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${YELLOW}4. Checking IAM Roles${NC}"
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# Check EKS cluster IAM role
cluster_role_arn=$(aws iam get-role --role-name redis-eks-cluster-role --query 'Role.Arn' --output text 2>/dev/null)
if [ -n "$cluster_role_arn" ] && [ "$cluster_role_arn" != "None" ]; then
    check_tags_aws "$cluster_role_arn" "IAM Role (EKS Cluster)" "$AWS_REGION1"
else
    echo -e "${YELLOW}⚠ IAM role 'redis-eks-cluster-role' not found (may not be created yet)${NC}"
    echo ""
fi

# Check EKS node IAM role
node_role_arn=$(aws iam get-role --role-name redis-eks-node-role --query 'Role.Arn' --output text 2>/dev/null)
if [ -n "$node_role_arn" ] && [ "$node_role_arn" != "None" ]; then
    check_tags_aws "$node_role_arn" "IAM Role (EKS Nodes)" "$AWS_REGION1"
else
    echo -e "${YELLOW}⚠ IAM role 'redis-eks-node-role' not found (may not be created yet)${NC}"
    echo ""
fi

echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${YELLOW}5. Summary - All Resources by Tag${NC}"
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

echo -e "${BLUE}All resources tagged with owner=$owner (Region 1):${NC}"
aws resourcegroupstaggingapi get-resources \
    --region "$AWS_REGION1" \
    --tag-filters "Key=owner,Values=$owner" \
    --query 'ResourceTagMappingList[].{ARN:ResourceARN}' \
    --output table 2>/dev/null || echo "No resources found"
echo ""

echo -e "${BLUE}All resources tagged with owner=$owner (Region 2):${NC}"
aws resourcegroupstaggingapi get-resources \
    --region "$AWS_REGION2" \
    --tag-filters "Key=owner,Values=$owner" \
    --query 'ResourceTagMappingList[].{ARN:ResourceARN}' \
    --output table 2>/dev/null || echo "No resources found"
echo ""
