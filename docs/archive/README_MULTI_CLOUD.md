# Multi-Cloud Support - Implementation Branch

**Branch**: `aws_gcp_support`  
**Status**: 📋 Planning Phase  
**Goal**: Enable Redis Enterprise Active/Active deployment on Azure (AKS), AWS (EKS), and GCP (GKE)

---

## 🎯 Overview

This branch implements multi-cloud support for the Redis Enterprise Active/Active demonstration project. The implementation ensures:

✅ **Single unified configuration** - One `config.sh` to rule them all  
✅ **Consistent tagging/labeling** - `owner` and `skip_deletion` across all clouds  
✅ **Cloud-agnostic Kubernetes operations** - Redis Enterprise works the same everywhere  
✅ **Provider-specific optimizations** - Uses best practices for each cloud  
✅ **Backward compatibility** - Existing Azure deployments continue to work  

---

## 📚 Documentation

### Planning & Design
- **[MULTI_CLOUD_SUPPORT_PLAN.md](MULTI_CLOUD_SUPPORT_PLAN.md)** - Detailed implementation plan with 6 phases
- **[EFFORT_ESTIMATION.md](EFFORT_ESTIMATION.md)** - Time, cost, and resource estimates
- **[VALIDATION_CHECKLIST.md](VALIDATION_CHECKLIST.md)** - Testing and validation checklist

### Quick Start
- **[QUICK_START_GUIDE.md](QUICK_START_GUIDE.md)** - Quick reference for deployment on any cloud
- **[config.example.sh](config.example.sh)** - Example configuration for all cloud providers

---

## 🚀 Quick Start (After Implementation)

### 1. Configure for Your Cloud

```bash
# Copy example configuration
cp config.example.sh config.sh

# Edit config.sh and set:
# - CLOUD_PROVIDER=azure|aws|gcp
# - owner=firstname_lastname
# - Cloud-specific settings (regions, project IDs, etc.)
```

### 2. Deploy

```bash
# Create everything
./scripts/create-all.sh

# Get cluster info
./scripts/05-get-cluster-info.sh

# Launch dashboard
./launch-flask-console.sh
```

### 3. Test & Monitor

```bash
# Run chaos tests
./scripts/chaos.sh

# Verify tags/labels
./scripts/check-tags.sh
```

### 4. Cleanup

```bash
# Delete all resources
./scripts/delete-all-resources.sh
```

---

## 📋 Implementation Phases

### Phase 1: Project Restructuring (4 hours)
- Reorganize project structure
- Add cloud provider selection to config.sh
- Ensure backward compatibility with Azure

**Status**: ⏳ Not Started

### Phase 2: AWS Support (12 hours)
- Implement EKS infrastructure with Terraform
- Add Route53 DNS integration
- Ensure all resources tagged with owner/skip_deletion
- Test full stack deployment

**Status**: ⏳ Not Started

### Phase 3: GCP Support (10 hours)
- Implement GKE infrastructure with Terraform
- Add Cloud DNS integration
- Ensure all resources labeled with owner/skip_deletion
- Test full stack deployment

**Status**: ⏳ Not Started

### Phase 4: Unified Kubernetes Operations (6 hours)
- Verify K8s operations work across all clouds
- Test cross-cloud Active/Active replication
- Update Flask dashboard for multi-cloud

**Status**: ⏳ Not Started

### Phase 5: Enhanced Tag/Label Checking (4 hours)
- Update check-tags.sh for all providers
- Create provider-specific validators

**Status**: ⏳ Not Started

### Phase 6: Documentation & Testing (8 hours)
- Complete documentation
- End-to-end testing on all clouds
- Migration guide

**Status**: ⏳ Not Started

**Total Estimated Effort**: 44 hours (1.5-2 weeks)

---

## 🏗️ New Project Structure (After Phase 1)

```
.
├── config.sh                          # Unified cloud configuration
├── config.example.sh                  # Example configuration
│
├── providers/                         # Cloud-specific infrastructure
│   ├── azure/
│   │   ├── main.tf                   # Azure resources (AKS)
│   │   ├── variables.tf
│   │   ├── outputs.tf
│   │   ├── get-credentials.sh        # Get AKS credentials
│   │   └── chaos-provider.sh         # Azure-specific chaos ops
│   ├── aws/
│   │   ├── main.tf                   # AWS resources (EKS)
│   │   ├── variables.tf
│   │   ├── outputs.tf
│   │   ├── get-credentials.sh        # Get EKS credentials
│   │   └── chaos-provider.sh         # AWS-specific chaos ops
│   └── gcp/
│       ├── main.tf                   # GCP resources (GKE)
│       ├── variables.tf
│       ├── outputs.tf
│       ├── get-credentials.sh        # Get GKE credentials
│       └── chaos-provider.sh         # GCP-specific chaos ops
│
├── scripts/                           # Cloud-agnostic orchestration
│   ├── 01-create-cluster.sh          # Creates K8s clusters
│   ├── 02-setup-haproxy.sh           # Installs HAProxy ingress
│   ├── 03-setup-rerc.sh              # Configures remote clusters
│   ├── 04-create-active-active-db.sh # Creates AA database
│   ├── 05-get-cluster-info.sh        # Gets connection info
│   ├── create-all.sh                 # Full deployment
│   ├── delete-all-resources.sh       # Full cleanup
│   ├── chaos.sh                      # Chaos testing
│   └── check-tags.sh                 # Tag/label validation
│
├── common/                            # Shared utilities
│   ├── dns-azure.sh                  # Azure DNS operations
│   ├── dns-aws.sh                    # Route53 operations
│   └── dns-gcp.sh                    # Cloud DNS operations
│
├── templates/                         # Kubernetes templates
├── flask/                             # Monitoring dashboard
└── docs/                              # Documentation
    ├── AZURE_SETUP.md
    ├── AWS_SETUP.md
    ├── GCP_SETUP.md
    └── MIGRATION.md
```

---

## 🏷️ Tag/Label Requirements

All cloud resources **must** have these tags/labels:

| Tag/Label | Format | Example | Required |
|-----------|--------|---------|----------|
| `owner` | firstname_lastname | thomas_manson | ✅ Yes |
| `skip_deletion` | yes\|no | yes | ✅ Yes |

### Implementation by Cloud

**Azure**: Uses `tags` on all resources
```hcl
tags = {
  owner         = var.owner
  skip_deletion = var.skip_deletion
}
```

**AWS**: Uses `tags` on all resources
```hcl
tags = {
  owner         = var.owner
  skip_deletion = var.skip_deletion
}
```

**GCP**: Uses `resource_labels` for GKE, `labels` for compute
```hcl
resource_labels = {
  owner         = var.owner
  skip_deletion = var.skip_deletion
}
```

---

## 🧪 Testing Strategy

### Unit Testing
- Each cloud provider infrastructure deploys independently
- Tag/label validation passes for each provider
- Cleanup scripts remove all resources

### Integration Testing
- HAProxy Ingress works on all clouds
- Redis Enterprise Operator deploys successfully
- Remote Cluster configuration works
- Active/Active database creation succeeds

### End-to-End Testing
- Full deployment on Azure
- Full deployment on AWS
- Full deployment on GCP
- Cross-cloud Active/Active (Azure-AWS, AWS-GCP, GCP-Azure)

### Chaos Testing
- Pod failure recovery
- Node/VM failure recovery
- Cluster stop/start (region outage)
- Database recovery verification

---

## 💰 Cost Estimates

### Per Cloud Provider (2 regions, 3 nodes each)

| Provider | Instance Type | Hourly | Daily | Monthly |
|----------|---------------|--------|-------|---------|
| **Azure** | 2x AKS (D8s_v3) | ~$2.50 | ~$60 | ~$1,800 |
| **AWS** | 2x EKS (m5.2xlarge) | ~$3.00 | ~$72 | ~$2,160 |
| **GCP** | 2x GKE (n1-standard-8) | ~$2.50 | ~$60 | ~$1,800 |

💡 **Always cleanup after testing to avoid charges!**

---

## 📖 Additional Resources

### Cloud Provider Documentation
- [Azure AKS](https://docs.microsoft.com/en-us/azure/aks/)
- [AWS EKS](https://docs.aws.amazon.com/eks/)
- [GCP GKE](https://cloud.google.com/kubernetes-engine/docs)

### Redis Enterprise
- [Redis Enterprise on Kubernetes](https://docs.redis.com/latest/kubernetes/)
- [Active/Active Databases](https://docs.redis.com/latest/rs/databases/active-active/)

### Terraform Providers
- [Azure Provider](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs)
- [AWS Provider](https://registry.terraform.io/providers/hashicorp/aws/latest/docs)
- [GCP Provider](https://registry.terraform.io/providers/hashicorp/google/latest/docs)

---

## 🤝 Contributing

This is a feature branch. To contribute:

1. Review the planning documents
2. Pick a phase from VALIDATION_CHECKLIST.md
3. Implement and test
4. Update checklist with progress
5. Create PR when phase is complete

---

## 📝 Current Status

**Phase**: Planning  
**Next Steps**:
1. Review and approve implementation plan
2. Start Phase 1: Project Restructuring
3. Validate Azure still works with new structure
4. Proceed to Phase 2 (AWS) or Phase 3 (GCP)

---

**Last Updated**: 2026-05-04  
**Maintainer**: Development Team  
**Version**: 1.0 (Planning)
