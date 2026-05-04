# Quick Start Guide - Multi-Cloud Support

Quick reference for deploying Redis Enterprise Active/Active on Azure, AWS, or GCP.

---

## Prerequisites

### Common Tools
```bash
# Install common tools
brew install kubectl helm jq opentofu
```

### Azure
```bash
brew install azure-cli
az login
az account set --subscription "YOUR_SUBSCRIPTION"
```

### AWS
```bash
brew install awscli
aws configure
# Enter: Access Key ID, Secret Access Key, Region, Output format
```

### GCP
```bash
brew install google-cloud-sdk
gcloud auth login
gcloud config set project YOUR_PROJECT_ID
```

---

## Configuration

### 1. Edit config.sh

Choose your cloud provider:

```bash
# For Azure
CLOUD_PROVIDER=azure

# For AWS
CLOUD_PROVIDER=aws

# For GCP
CLOUD_PROVIDER=gcp
```

### 2. Set Required Variables

#### Azure Configuration
```bash
CLOUD_PROVIDER=azure
CLUSTER_RESOURCE_GROUP=YourName-temp-AKS
DNS_RESOURCE_GROUP=YourName
DNS_ZONE=demo.yourdomain.com
owner=firstname_lastname
skip_deletion=yes
```

#### AWS Configuration
```bash
CLOUD_PROVIDER=aws
CLUSTER_RESOURCE_GROUP=YourName-temp-EKS  # Used as tag value
DNS_ZONE=demo.yourdomain.com
AWS_REGION1=us-east-1
AWS_REGION2=us-west-2
owner=firstname_lastname
skip_deletion=yes
```

#### GCP Configuration
```bash
CLOUD_PROVIDER=gcp
GCP_PROJECT_ID=your-project-id
DNS_ZONE=demo.yourdomain.com
GCP_REGION1=us-central1
GCP_REGION2=europe-west1
owner=firstname_lastname
skip_deletion=yes
```

---

## Deployment

### Quick Deploy (All Providers)

```bash
# 1. Create infrastructure and Redis Enterprise
./scripts/create-all.sh

# 2. Get cluster information
./scripts/05-get-cluster-info.sh

# 3. Launch monitoring dashboard
./launch-flask-console.sh
# Open browser: http://localhost:5000
```

### Verify Tags/Labels

```bash
# Check that all resources have proper tags/labels
./scripts/check-tags.sh
```

---

## Step-by-Step Deployment

### 1. Create Kubernetes Clusters

```bash
./scripts/01-create-cluster.sh
```

**What it does**:
- Azure: Creates 2 AKS clusters with tags
- AWS: Creates 2 EKS clusters with tags
- GCP: Creates 2 GKE clusters with labels

### 2. Setup HAProxy Ingress

```bash
./scripts/02-setup-haproxy.sh
```

**What it does**:
- Installs HAProxy Ingress Controller
- Deploys Redis Enterprise Operator
- Creates DNS records for clusters

### 3. Configure Remote Clusters

```bash
./scripts/03-setup-rerc.sh
```

**What it does**:
- Sets up Redis Enterprise Remote Cluster (RERC) objects
- Configures cross-cluster communication

### 4. Create Active/Active Database

```bash
./scripts/04-create-active-active-db.sh
```

**What it does**:
- Creates Active/Active database across both regions
- Configures automatic conflict resolution

---

## Testing & Chaos Engineering

### Run Chaos Tests

```bash
# Test on primary cluster (default)
./scripts/chaos.sh

# Test on specific cluster
./scripts/chaos.sh redis-ukwest  # Azure
./scripts/chaos.sh redis-us-west-2  # AWS
./scripts/chaos.sh redis-europe-west1  # GCP
```

**What it tests**:
1. Pod failure and recovery
2. Node/VM failure and recovery
3. Cluster stop/start (region outage simulation)
4. Database recovery after outage

---

## Monitoring

### Launch Web Dashboard

```bash
./launch-flask-console.sh
```

Open browser to `http://localhost:5000` to see:
- Cluster health status
- Database replication status
- Real-time key counts
- Region availability

### Manual Cluster Info

```bash
# Get connection strings, credentials, etc.
./scripts/05-get-cluster-info.sh
```

---

## Cleanup

### Delete All Resources

```bash
./scripts/delete-all-resources.sh
```

**What it does**:
- Deletes Kubernetes namespaces
- Destroys K8s clusters (AKS/EKS/GKE)
- Removes DNS records
- Cleans up all cloud resources

### Verify Cleanup

```bash
# Azure
az group show --name $CLUSTER_RESOURCE_GROUP  # Should error

# AWS
aws eks list-clusters --region us-east-1  # Should not show your clusters

# GCP
gcloud container clusters list  # Should not show your clusters
```

---

## Troubleshooting

### Check Cloud Authentication

```bash
# Azure
az account show

# AWS
aws sts get-caller-identity

# GCP
gcloud auth list
gcloud config get-value project
```

### Check Kubernetes Context

```bash
# List available contexts
kubectl config get-contexts

# Switch context
kubectl config use-context redis-francecentral  # Azure
kubectl config use-context redis-us-east-1      # AWS
kubectl config use-context gke_project_region_cluster  # GCP

# Test connectivity
kubectl get nodes
```

### Check Tags/Labels

```bash
# Run the validation script
./scripts/check-tags.sh

# Manual checks:

# Azure
az group show --name $CLUSTER_RESOURCE_GROUP --query tags
az aks show --name redis-francecentral -g $CLUSTER_RESOURCE_GROUP --query tags

# AWS
aws eks describe-cluster --name redis-us-east-1 --query 'cluster.tags'
aws resourcegroupstaggingapi get-resources --tag-filters Key=owner,Values=YOUR_NAME

# GCP
gcloud container clusters describe redis-us-central1 --region=us-central1 --format="value(resourceLabels)"
gcloud compute instances list --filter="labels.owner=YOUR_NAME"
```

### Common Issues

#### Issue: "Cluster not found"
**Solution**: Verify cluster name matches config.sh and deployment completed successfully

#### Issue: "Permission denied"
**Solution**: Check cloud provider authentication and IAM/RBAC permissions

#### Issue: "Tags not applied"
**Solution**: Ensure `owner` and `skip_deletion` are set in config.sh before deployment

#### Issue: "DNS resolution fails"
**Solution**: Wait for DNS propagation (can take 5-10 minutes), verify DNS zone configuration

---

## Cost Management

### Estimated Costs (per hour)

| Provider | Configuration | Estimated Cost/Hour |
|----------|---------------|---------------------|
| Azure | 2x AKS (3 nodes, D8s_v3) | ~$2-3/hour |
| AWS | 2x EKS (3 nodes, m5.2xlarge) | ~$2.50-3.50/hour |
| GCP | 2x GKE (3 nodes, n1-standard-8) | ~$2-3/hour |

**💡 Tip**: Always run `delete-all-resources.sh` after testing to avoid unnecessary charges!

### Set Budget Alerts

#### Azure
```bash
az consumption budget create --budget-name redis-demo --amount 100 --time-grain monthly
```

#### AWS
```bash
# Use AWS Budgets console or CLI
aws budgets create-budget --account-id YOUR_ACCOUNT --budget ...
```

#### GCP
```bash
# Use GCP Billing console to set budget alerts
```

---

## Next Steps

1. **Read Full Documentation**: See `MULTI_CLOUD_SUPPORT_PLAN.md`
2. **Review Validation Checklist**: See `VALIDATION_CHECKLIST.md`
3. **Provider-Specific Guides**:
   - `docs/AZURE_SETUP.md`
   - `docs/AWS_SETUP.md`
   - `docs/GCP_SETUP.md`

---

**Document Version**: 1.0  
**Branch**: aws_gcp_support  
**Last Updated**: 2026-05-04
