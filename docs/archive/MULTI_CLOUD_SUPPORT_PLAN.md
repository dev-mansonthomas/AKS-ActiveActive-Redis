# Multi-Cloud Support Implementation Plan
## AWS & GCP Support for Redis Enterprise Active/Active

**Branch**: `aws_gcp_support`  
**Goal**: Enable deployment of Redis Enterprise Active/Active on AWS (EKS) and GCP (GKE) while maintaining Azure (AKS) support  
**Key Requirement**: All resources must have `owner` and `skip_deletion` labels/tags across all cloud providers

---

## 📋 Current State Analysis

### Existing Azure Implementation
- **Infrastructure**: OpenTofu/Terraform with Azure provider
- **K8s Clusters**: AKS clusters in 2 regions
- **DNS**: Azure DNS Zone with wildcard records
- **Networking**: HAProxy Ingress with public IPs
- **Tags**: `owner` and `skip_deletion` applied to all resources
- **Scripts**: Bash scripts for deployment, chaos testing, monitoring

### Cloud-Specific Components
| Component | Azure | AWS Equivalent | GCP Equivalent |
|-----------|-------|----------------|----------------|
| K8s Service | AKS | EKS | GKE |
| Resource Grouping | Resource Group | Tags | Labels/Projects |
| DNS | Azure DNS | Route53 | Cloud DNS |
| CLI | `az` | `aws` | `gcloud` |
| Node VM Type | `Standard_D8s_v3` | `m5.2xlarge` | `n1-standard-8` |
| Metadata | Tags | Tags | Labels |

---

## 🎯 Implementation Strategy

### Approach: Modular Infrastructure with Cloud Abstraction

**Principles**:
1. Keep Kubernetes/Redis Enterprise logic cloud-agnostic
2. Isolate cloud-specific IaC in separate directories
3. Unified config.sh with cloud provider selection
4. Common scripts that detect and use the appropriate cloud CLI
5. Ensure tags/labels consistency across all providers

---

## 📦 Phase 1: Project Restructuring (Foundation)

**Goal**: Reorganize project to support multiple cloud providers without breaking existing Azure deployment

### Tasks

#### 1.1 Create New Directory Structure
```
├── config.sh                          # Unified config with CLOUD_PROVIDER variable
├── providers/
│   ├── azure/
│   │   ├── main.tf                   # Azure-specific IaC
│   │   ├── variables.tf
│   │   ├── outputs.tf
│   │   ├── get-credentials.sh        # az aks get-credentials wrapper
│   │   └── chaos-provider.sh         # Azure-specific chaos operations
│   ├── aws/
│   │   ├── main.tf                   # AWS-specific IaC (EKS)
│   │   ├── variables.tf
│   │   ├── outputs.tf
│   │   ├── get-credentials.sh        # aws eks update-kubeconfig wrapper
│   │   └── chaos-provider.sh         # AWS-specific chaos operations
│   └── gcp/
│       ├── main.tf                   # GCP-specific IaC (GKE)
│       ├── variables.tf
│       ├── outputs.tf
│       ├── get-credentials.sh        # gcloud container clusters get-credentials wrapper
│       └── chaos-provider.sh         # GCP-specific chaos operations
├── scripts/
│   ├── 01-create-cluster.sh          # Cloud-agnostic wrapper
│   ├── 02-setup-haproxy.sh           # Same (K8s-agnostic)
│   ├── 03-setup-rerc.sh              # Same (K8s-agnostic)
│   ├── 04-create-active-active-db.sh # Same (K8s-agnostic)
│   ├── 05-get-cluster-info.sh        # Cloud-agnostic wrapper
│   ├── create-all.sh                 # Updated orchestrator
│   ├── delete-all-resources.sh       # Cloud-agnostic wrapper
│   ├── chaos.sh                      # Cloud-agnostic wrapper
│   └── check-tags.sh                 # Updated for all providers
└── common/
    ├── dns-azure.sh                  # Azure DNS operations
    ├── dns-aws.sh                    # Route53 operations
    └── dns-gcp.sh                    # Cloud DNS operations
```

#### 1.2 Update config.sh
Add cloud provider selection:
```bash
# Cloud Provider Selection
# Values: azure, aws, gcp
CLOUD_PROVIDER=azure

# Cloud-specific configurations
case $CLOUD_PROVIDER in
  azure)
    CLUSTER_RESOURCE_GROUP=ThomasManson-temp-AKS
    DNS_RESOURCE_GROUP=ThomasManson
    INSTANCE_TYPE=Standard_D8s_v3
    ;;
  aws)
    CLUSTER_RESOURCE_GROUP=ThomasManson-temp-EKS  # AWS doesn't use RGs, this becomes a tag
    INSTANCE_TYPE=m5.2xlarge
    AWS_REGION1=us-east-1
    AWS_REGION2=us-west-2
    ;;
  gcp)
    GCP_PROJECT_ID=my-redis-project
    INSTANCE_TYPE=n1-standard-8
    GCP_REGION1=us-central1
    GCP_REGION2=europe-west1
    ;;
esac
```

**Validation**:
- ✅ Run `source config.sh` for each provider
- ✅ Verify variables are set correctly
- ✅ No breaking changes to existing Azure setup

**Estimated Time**: 4 hours

---

## 📦 Phase 2: AWS Support (EKS)

**Goal**: Complete AWS/EKS infrastructure deployment with full tag support

### Tasks

#### 2.1 Create AWS Terraform Module (`providers/aws/`)

**Files to create**:
- `providers/aws/main.tf` - EKS clusters with node groups
- `providers/aws/variables.tf` - AWS-specific variables
- `providers/aws/outputs.tf` - Cluster endpoints, kubeconfig data

**Key Resources**:
```hcl
# VPC for EKS
resource "aws_vpc" "main" {
  tags = {
    owner         = var.owner
    skip_deletion = var.skip_deletion
    Name          = "${var.cluster_resource_group}-vpc"
  }
}

# EKS Cluster 1
resource "aws_eks_cluster" "cluster1" {
  name = "redis-${var.region1}"
  tags = {
    owner         = var.owner
    skip_deletion = var.skip_deletion
  }
}

# Node Group (inherits cluster tags + adds own)
resource "aws_eks_node_group" "cluster1_nodes" {
  tags = {
    owner         = var.owner
    skip_deletion = var.skip_deletion
  }
}
```

**Tag Requirements**:
- ✅ VPC
- ✅ Subnets
- ✅ EKS Clusters
- ✅ Node Groups
- ✅ Security Groups
- ✅ IAM Roles (use tags where supported)

#### 2.2 Create AWS DNS Module (`common/dns-aws.sh`)

**Operations**:
```bash
# Create hosted zone (if not exists)
aws route53 create-hosted-zone --name $DNS_ZONE

# Create A record for cluster
aws route53 change-resource-record-sets \
  --hosted-zone-id $HOSTED_ZONE_ID \
  --change-batch file://change-batch.json

# Tag resources
aws route53 tag-resource \
  --resource-type hostedzone \
  --resource-id $HOSTED_ZONE_ID \
  --add-tags Key=owner,Value=$owner Key=skip_deletion,Value=$skip_deletion
```

#### 2.3 Create AWS-Specific Scripts

**`providers/aws/get-credentials.sh`**:
```bash
#!/usr/bin/env bash
source ../../config.sh
aws eks update-kubeconfig --name $CLUSTER1 --region $AWS_REGION1 --alias $CLUSTER1
aws eks update-kubeconfig --name $CLUSTER2 --region $AWS_REGION2 --alias $CLUSTER2
```

**`providers/aws/chaos-provider.sh`**:
```bash
# Stop EKS cluster (scale node group to 0)
aws eks update-nodegroup-config \
  --cluster-name $cluster \
  --nodegroup-name $nodegroup \
  --scaling-config minSize=0,maxSize=0,desiredSize=0

# Restart node in autoscaling group
aws autoscaling terminate-instance-in-auto-scaling-group \
  --instance-id $instance_id \
  --should-decrement-desired-capacity
```

#### 2.4 Update Main Scripts for AWS Detection

**`scripts/01-create-cluster.sh`**:
```bash
#!/usr/bin/env bash
source ./config.sh

case $CLOUD_PROVIDER in
  azure)
    cd providers/azure
    TF_VAR_subscription_id=$(az account show --query id -o tsv)
    TF_VAR_azure_rg=$CLUSTER_RESOURCE_GROUP
    ;;
  aws)
    cd providers/aws
    export AWS_DEFAULT_REGION=$AWS_REGION1
    TF_VAR_aws_account_id=$(aws sts get-caller-identity --query Account --output text)
    ;;
  gcp)
    cd providers/gcp
    gcloud config set project $GCP_PROJECT_ID
    ;;
esac

TF_VAR_owner=$owner
TF_VAR_skip_deletion=$skip_deletion
export TF_VAR_owner TF_VAR_skip_deletion

tofu init
tofu apply -auto-approve
cd ../..
```

**Validation & Testing**:
1. ✅ Deploy to AWS using config with `CLOUD_PROVIDER=aws`
2. ✅ Verify EKS clusters created in both regions
3. ✅ Verify all resources have both tags: `owner` and `skip_deletion`
4. ✅ Verify kubectl contexts work
5. ✅ Run `check-tags.sh` for AWS
6. ✅ Deploy HAProxy, Redis Enterprise Operator (phases 3-4)
7. ✅ Test chaos scenarios

**Estimated Time**: 12 hours

---

## 📦 Phase 3: GCP Support (GKE)

**Goal**: Complete GCP/GKE infrastructure deployment with full label support

### Tasks

#### 3.1 Create GCP Terraform Module (`providers/gcp/`)

**Files to create**:
- `providers/gcp/main.tf` - GKE clusters
- `providers/gcp/variables.tf` - GCP-specific variables
- `providers/gcp/outputs.tf` - Cluster endpoints

**Key Resources**:
```hcl
# GKE Cluster 1
resource "google_container_cluster" "cluster1" {
  name     = "redis-${var.region1}"
  location = var.region1

  resource_labels = {
    owner         = var.owner
    skip_deletion = var.skip_deletion
  }

  node_pool {
    node_config {
      machine_type = var.instance_type
      labels = {
        owner         = var.owner
        skip_deletion = var.skip_deletion
      }
    }
  }
}

# GCP uses resource_labels for GKE clusters and labels for nodes
```

**Label Requirements**:
- ✅ GKE Clusters (`resource_labels`)
- ✅ Node Pools (`labels` in node_config)
- ✅ Compute Instances (auto-labeled by GKE)
- ✅ Persistent Disks (inherit from cluster)
- ✅ VPC Network (use `labels`)

#### 3.2 Create GCP DNS Module (`common/dns-gcp.sh`)

**Operations**:
```bash
# Create DNS zone
gcloud dns managed-zones create redis-zone \
  --dns-name=$DNS_ZONE \
  --description="Redis Enterprise AA" \
  --labels=owner=$owner,skip_deletion=$skip_deletion

# Add A record
gcloud dns record-sets create "*.$CLUSTER1.$DNS_ZONE" \
  --zone=redis-zone \
  --type=A \
  --ttl=300 \
  --rrdatas=$CLUSTER_IP
```

#### 3.3 Create GCP-Specific Scripts

**`providers/gcp/get-credentials.sh`**:
```bash
#!/usr/bin/env bash
source ../../config.sh
gcloud container clusters get-credentials $CLUSTER1 --region $GCP_REGION1
gcloud container clusters get-credentials $CLUSTER2 --region $GCP_REGION2
```

**`providers/gcp/chaos-provider.sh`**:
```bash
# Stop GKE cluster (scale to 0)
gcloud container clusters resize $cluster \
  --num-nodes=0 \
  --region=$region \
  --quiet

# Restart a node (delete instance, GKE recreates)
gcloud compute instances delete $instance_name \
  --zone=$zone \
  --quiet
```

**Validation & Testing**:
1. ✅ Deploy to GCP using config with `CLOUD_PROVIDER=gcp`
2. ✅ Verify GKE clusters created in both regions
3. ✅ Verify all resources have labels: `owner` and `skip_deletion`
4. ✅ Run `check-tags.sh` for GCP (update to check labels)
5. ✅ Deploy full stack (HAProxy + Redis)
6. ✅ Test chaos scenarios

**Estimated Time**: 10 hours

---

## 📦 Phase 4: Unified Kubernetes Operations

**Goal**: Ensure all K8s operations work across all cloud providers

### Tasks

#### 4.1 Verify Cloud-Agnostic Scripts

These scripts should work without modification:
- ✅ `02-setup-haproxy.sh` - HAProxy ingress (K8s native)
- ✅ `03-setup-rerc.sh` - Redis Enterprise Remote Cluster
- ✅ `04-create-active-active-db.sh` - Active/Active DB creation

**Changes Needed**: Only in getting cluster credentials (handled by provider scripts)

#### 4.2 Update DNS Scripts

Create dispatcher in main scripts:
```bash
case $CLOUD_PROVIDER in
  azure) source common/dns-azure.sh ;;
  aws)   source common/dns-aws.sh ;;
  gcp)   source common/dns-gcp.sh ;;
esac
```

#### 4.3 Update Flask Dashboard

**`flask/k8s.py`**: Add cloud provider detection
```python
cloud_provider = get_config_var("CLOUD_PROVIDER")

def get_cluster_info(cluster_name):
    if cloud_provider == "azure":
        # Use Azure-specific APIs if needed
        pass
    # kubectl operations work the same across all providers
    return kubectl_get_pods(cluster_name)
```

**Validation**:
1. ✅ Deploy full stack on Azure
2. ✅ Deploy full stack on AWS
3. ✅ Deploy full stack on GCP
4. ✅ Verify Flask dashboard works for all
5. ✅ Verify Active/Active replication works across clouds

**Estimated Time**: 6 hours

---

## 📦 Phase 5: Enhanced Tag/Label Checking

**Goal**: Update check-tags.sh to verify tags/labels across all providers

### Tasks

#### 5.1 Update `check-tags.sh`

Add cloud-specific checking logic:
```bash
case $CLOUD_PROVIDER in
  azure)
    # Check Azure tags (existing logic)
    az resource list --tag owner=$owner
    ;;
  aws)
    # Check AWS tags
    aws resourcegroupstaggingapi get-resources \
      --tag-filters "Key=owner,Values=$owner" \
      --resource-type-filters "eks" "ec2"
    ;;
  gcp)
    # Check GCP labels
    gcloud compute instances list \
      --filter="labels.owner=$owner"
    gcloud container clusters list \
      --filter="resourceLabels.owner=$owner"
    ;;
esac
```

#### 5.2 Create Provider-Specific Tag Validators

**`providers/azure/check-tags.sh`**
**`providers/aws/check-tags.sh`**
**`providers/gcp/check-labels.sh`**

Each validates provider-specific resources

**Validation**:
1. ✅ Run check-tags.sh with CLOUD_PROVIDER=azure
2. ✅ Run check-tags.sh with CLOUD_PROVIDER=aws
3. ✅ Run check-tags.sh with CLOUD_PROVIDER=gcp
4. ✅ Verify all resources properly tagged/labeled

**Estimated Time**: 4 hours

---

## 📦 Phase 6: Documentation & Testing

**Goal**: Complete documentation and end-to-end testing

### Tasks

#### 6.1 Update README.md

Add multi-cloud sections:
- Prerequisites for each cloud provider (CLI tools, credentials)
- Configuration examples for Azure, AWS, GCP
- Tag/Label requirements by provider
- Troubleshooting by provider

#### 6.2 Create Provider-Specific Guides

**`docs/AZURE_SETUP.md`** - Azure-specific setup
**`docs/AWS_SETUP.md`** - AWS-specific setup (IAM, VPC, etc.)
**`docs/GCP_SETUP.md`** - GCP-specific setup (projects, service accounts)

#### 6.3 End-to-End Testing Matrix

| Test Scenario | Azure | AWS | GCP |
|---------------|-------|-----|-----|
| Create clusters | ✅ | ✅ | ✅ |
| Deploy Redis Enterprise | ✅ | ✅ | ✅ |
| Active/Active DB | ✅ | ✅ | ✅ |
| Pod failure recovery | ✅ | ✅ | ✅ |
| Node failure recovery | ✅ | ✅ | ✅ |
| Region outage simulation | ✅ | ✅ | ✅ |
| Tag/Label verification | ✅ | ✅ | ✅ |
| Full cleanup | ✅ | ✅ | ✅ |

#### 6.4 Create Migration Guide

**`docs/MIGRATION.md`**: Guide for existing Azure users to understand new structure

**Validation**:
1. ✅ Fresh deployment on each cloud provider
2. ✅ Run full chaos testing suite
3. ✅ Verify documentation accuracy
4. ✅ Test cleanup scripts

**Estimated Time**: 8 hours

---

## 📊 Summary & Timeline

### Total Effort Estimation

| Phase | Description | Duration | Validation |
|-------|-------------|----------|------------|
| **Phase 1** | Project Restructuring | 4 hours | Config source test |
| **Phase 2** | AWS/EKS Support | 12 hours | Full deployment + chaos |
| **Phase 3** | GCP/GKE Support | 10 hours | Full deployment + chaos |
| **Phase 4** | Unified K8s Ops | 6 hours | Cross-cloud testing |
| **Phase 5** | Tag Checking | 4 hours | Validate all tags/labels |
| **Phase 6** | Docs & Testing | 8 hours | E2E test matrix |
| **TOTAL** | | **44 hours** | **~1.5 weeks** |

### Success Criteria

- ✅ Deploy Redis Enterprise Active/Active on Azure (existing + refactored)
- ✅ Deploy Redis Enterprise Active/Active on AWS (new)
- ✅ Deploy Redis Enterprise Active/Active on GCP (new)
- ✅ All resources tagged/labeled with `owner` and `skip_deletion`
- ✅ Chaos testing works on all providers
- ✅ Flask dashboard works for all providers
- ✅ Single `config.sh` switches between providers
- ✅ Tag verification script validates all resources
- ✅ Complete documentation for all providers
- ✅ No breaking changes to existing Azure deployments

### Key Risks & Mitigations

| Risk | Mitigation |
|------|------------|
| Breaking existing Azure setup | Phase 1 creates new structure, migrate carefully |
| Provider-specific K8s differences | Use cloud-agnostic features, document limitations |
| Tag/Label name restrictions | Normalize to lowercase, no special chars |
| DNS propagation differences | Use provider-specific TTL recommendations |
| Cost overruns during testing | Use smallest viable instance types, cleanup scripts |

---

## 🚀 Getting Started

### Immediate Next Steps

1. **Review & Approve Plan** - Stakeholder review of this document
2. **Phase 1: Start Restructuring** - Create directory structure
3. **Phase 1: Update config.sh** - Add CLOUD_PROVIDER selection
4. **Phase 1: Validate** - Test Azure deployment with new structure
5. **Phase 2: Begin AWS Implementation** - Start with Terraform module

### Branch Strategy

- `aws_gcp_support` - Main development branch
- Merge to `main` after each phase validation passes
- Tag releases: `v2.0-azure-only`, `v2.1-aws-support`, `v2.2-gcp-support`

---

**Document Version**: 1.0
**Last Updated**: 2026-05-04
**Author**: Development Team
**Status**: 📋 Planning Phase
