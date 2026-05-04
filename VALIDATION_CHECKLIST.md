# Multi-Cloud Support - Validation Checklist

This document tracks the validation and testing progress for each phase of the multi-cloud implementation.

---

## Phase 1: Project Restructuring ⏳

**Status**: Not Started  
**Target Completion**: TBD

### Pre-Implementation Checklist
- [ ] Backup current working Azure deployment
- [ ] Create `providers/` directory structure
- [ ] Create `scripts/` directory
- [ ] Create `common/` directory

### Implementation Checklist
- [ ] Move `main.tf` → `providers/azure/main.tf`
- [ ] Move `variables.tf` → `providers/azure/variables.tf`
- [ ] Move `output.tf` → `providers/azure/outputs.tf`
- [ ] Create `providers/azure/get-credentials.sh`
- [ ] Create `providers/azure/chaos-provider.sh`
- [ ] Move scripts to `scripts/` directory
- [ ] Update all script paths and references

### config.sh Updates
- [ ] Add `CLOUD_PROVIDER` variable
- [ ] Add Azure-specific configuration block
- [ ] Add AWS configuration block (placeholders)
- [ ] Add GCP configuration block (placeholders)
- [ ] Test `source config.sh` with CLOUD_PROVIDER=azure

### Validation Tests
- [ ] `source config.sh` succeeds with CLOUD_PROVIDER=azure
- [ ] All Azure variables are set correctly
- [ ] Existing Azure deployment still works with new structure
- [ ] `./scripts/create-all.sh` creates Azure clusters successfully
- [ ] `./scripts/delete-all-resources.sh` cleans up properly
- [ ] No regression in existing functionality

**Sign-off**: _______________ Date: _______________

---

## Phase 2: AWS Support (EKS) ⏳

**Status**: Not Started  
**Target Completion**: TBD

### AWS Prerequisites
- [ ] AWS CLI installed and configured
- [ ] AWS credentials set up (`aws configure`)
- [ ] IAM permissions validated for EKS
- [ ] Route53 hosted zone ready or permission to create
- [ ] Selected AWS regions support EKS

### Infrastructure Implementation
- [ ] Create `providers/aws/main.tf`
  - [ ] VPC resource with tags
  - [ ] Subnets with tags
  - [ ] EKS cluster 1 with tags
  - [ ] EKS cluster 2 with tags
  - [ ] Node groups with tags
  - [ ] Security groups with tags
- [ ] Create `providers/aws/variables.tf`
- [ ] Create `providers/aws/outputs.tf`
- [ ] Create `providers/aws/get-credentials.sh`
- [ ] Create `providers/aws/chaos-provider.sh`

### DNS Implementation
- [ ] Create `common/dns-aws.sh`
- [ ] Test Route53 zone creation
- [ ] Test A record creation
- [ ] Test tag application to DNS resources

### Script Updates
- [ ] Update `scripts/01-create-cluster.sh` for AWS
- [ ] Update `scripts/delete-all-resources.sh` for AWS
- [ ] Update `scripts/chaos.sh` for AWS
- [ ] Update `scripts/05-get-cluster-info.sh` for AWS

### Tag Validation
- [ ] VPC tagged with `owner` and `skip_deletion`
- [ ] Subnets tagged
- [ ] EKS clusters tagged
- [ ] Node groups tagged
- [ ] Security groups tagged
- [ ] Route53 hosted zone tagged
- [ ] All EC2 instances (nodes) tagged

### Functional Tests
- [ ] Deploy EKS clusters in 2 regions
- [ ] Verify kubectl contexts work
- [ ] Deploy HAProxy Ingress
- [ ] Deploy Redis Enterprise Operator
- [ ] Create Redis Enterprise Clusters
- [ ] Create Active/Active Database
- [ ] Verify replication works between regions
- [ ] Run `check-tags.sh` - all resources properly tagged

### Chaos Testing
- [ ] Pod failure recovery works
- [ ] Node termination recovery works
- [ ] EKS cluster stop/start works
- [ ] Region failover works
- [ ] Flask dashboard shows correct status

### Cleanup Test
- [ ] `delete-all-resources.sh` removes all AWS resources
- [ ] No orphaned resources remain
- [ ] Cost verification: $0 after cleanup

**Sign-off**: _______________ Date: _______________

---

## Phase 3: GCP Support (GKE) ⏳

**Status**: Not Started  
**Target Completion**: TBD

### GCP Prerequisites
- [ ] gcloud CLI installed
- [ ] GCP project created
- [ ] Service account created with necessary permissions
- [ ] gcloud authentication configured
- [ ] Selected GCP regions support GKE
- [ ] Cloud DNS API enabled

### Infrastructure Implementation
- [ ] Create `providers/gcp/main.tf`
  - [ ] VPC network with labels
  - [ ] GKE cluster 1 with resource_labels
  - [ ] GKE cluster 2 with resource_labels
  - [ ] Node pools with labels
- [ ] Create `providers/gcp/variables.tf`
- [ ] Create `providers/gcp/outputs.tf`
- [ ] Create `providers/gcp/get-credentials.sh`
- [ ] Create `providers/gcp/chaos-provider.sh`

### DNS Implementation
- [ ] Create `common/dns-gcp.sh`
- [ ] Test Cloud DNS zone creation
- [ ] Test A record creation
- [ ] Test label application to DNS resources

### Script Updates
- [ ] Update `scripts/01-create-cluster.sh` for GCP
- [ ] Update `scripts/delete-all-resources.sh` for GCP
- [ ] Update `scripts/chaos.sh` for GCP
- [ ] Update `scripts/05-get-cluster-info.sh` for GCP

### Label Validation
- [ ] VPC labeled with `owner` and `skip_deletion`
- [ ] GKE clusters have `resource_labels`
- [ ] Node pools have `labels`
- [ ] Compute instances labeled
- [ ] Cloud DNS zone labeled
- [ ] Persistent disks labeled

### Functional Tests
- [ ] Deploy GKE clusters in 2 regions
- [ ] Verify kubectl contexts work
- [ ] Deploy HAProxy Ingress
- [ ] Deploy Redis Enterprise Operator
- [ ] Create Redis Enterprise Clusters
- [ ] Create Active/Active Database
- [ ] Verify replication works between regions
- [ ] Run `check-tags.sh` - all resources properly labeled

### Chaos Testing
- [ ] Pod failure recovery works
- [ ] Node deletion recovery works
- [ ] GKE cluster resize works
- [ ] Region failover works
- [ ] Flask dashboard shows correct status

### Cleanup Test
- [ ] `delete-all-resources.sh` removes all GCP resources
- [ ] No orphaned resources remain
- [ ] Cost verification: $0 after cleanup

**Sign-off**: _______________ Date: _______________

---

## Phase 4: Unified Kubernetes Operations ⏳

**Status**: Not Started  
**Target Completion**: TBD

### Cross-Cloud K8s Verification
- [ ] HAProxy works identically on Azure/AWS/GCP
- [ ] Redis Enterprise Operator works on all clouds
- [ ] RERC (Remote Cluster) works across clouds
- [ ] Active/Active DB creation works on all clouds
- [ ] Ingress public IP retrieval works on all clouds

### DNS Integration Tests
- [ ] Azure DNS records created correctly
- [ ] Route53 records created correctly
- [ ] Cloud DNS records created correctly
- [ ] DNS propagation verified for all providers
- [ ] Wildcard DNS works for all providers

### Flask Dashboard Updates
- [ ] Dashboard detects cloud provider
- [ ] Dashboard shows cluster info for Azure
- [ ] Dashboard shows cluster info for AWS
- [ ] Dashboard shows cluster info for GCP
- [ ] Dashboard handles multi-cloud deployments

### Cross-Cloud Active/Active Test
- [ ] Deploy cluster1 on Azure, cluster2 on AWS
- [ ] Deploy cluster1 on AWS, cluster2 on GCP
- [ ] Deploy cluster1 on GCP, cluster2 on Azure
- [ ] Verify replication works across different clouds
- [ ] Verify failover works across clouds

**Sign-off**: _______________ Date: _______________

---

## Phase 5: Enhanced Tag/Label Checking ⏳

**Status**: Not Started  
**Target Completion**: TBD

### check-tags.sh Updates
- [ ] Add Azure tag checking (existing)
- [ ] Add AWS tag checking
- [ ] Add GCP label checking
- [ ] Add provider auto-detection
- [ ] Add summary report for multi-cloud

### Provider-Specific Validators
- [ ] Create `providers/azure/check-tags.sh`
- [ ] Create `providers/aws/check-tags.sh`
- [ ] Create `providers/gcp/check-labels.sh`

### Validation Tests
- [ ] Run with CLOUD_PROVIDER=azure → all tags verified
- [ ] Run with CLOUD_PROVIDER=aws → all tags verified
- [ ] Run with CLOUD_PROVIDER=gcp → all labels verified
- [ ] False positive test: detects missing tags correctly
- [ ] False positive test: detects incorrect tag values

**Sign-off**: _______________ Date: _______________

---

## Phase 6: Documentation & Testing ⏳

**Status**: Not Started  
**Target Completion**: TBD

### Documentation
- [ ] Update README.md with multi-cloud section
- [ ] Create `docs/AZURE_SETUP.md`
- [ ] Create `docs/AWS_SETUP.md`
- [ ] Create `docs/GCP_SETUP.md`
- [ ] Create `docs/MIGRATION.md`
- [ ] Update config.sh documentation
- [ ] Document tag/label requirements per provider
- [ ] Add troubleshooting section per provider

### End-to-End Testing

#### Azure Full Stack
- [ ] Fresh deployment
- [ ] Full chaos test suite
- [ ] Tag verification
- [ ] Cleanup verification

#### AWS Full Stack
- [ ] Fresh deployment
- [ ] Full chaos test suite
- [ ] Tag verification
- [ ] Cleanup verification

#### GCP Full Stack
- [ ] Fresh deployment
- [ ] Full chaos test suite
- [ ] Label verification
- [ ] Cleanup verification

### Performance Testing
- [ ] Deployment time comparison (Azure/AWS/GCP)
- [ ] Cost comparison for same workload
- [ ] Network latency between regions

### User Acceptance Testing
- [ ] New user follows docs to deploy on Azure
- [ ] New user follows docs to deploy on AWS
- [ ] New user follows docs to deploy on GCP
- [ ] Migration from old structure to new works smoothly

**Sign-off**: _______________ Date: _______________

---

## Final Release Checklist ✅

- [ ] All 6 phases completed and signed off
- [ ] No known critical bugs
- [ ] All documentation reviewed and accurate
- [ ] All tests passing on all cloud providers
- [ ] Tag/label compliance verified on all providers
- [ ] Backward compatibility with existing Azure deployments verified
- [ ] Migration guide tested
- [ ] Release notes prepared
- [ ] Version tagged in git

**Final Sign-off**: _______________ Date: _______________

---

**Document Version**: 1.0  
**Branch**: aws_gcp_support  
**Status**: 📋 Ready for Phase 1
