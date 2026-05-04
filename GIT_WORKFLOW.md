# Git Workflow - Multi-Cloud Support Branch

Guide for managing the `aws_gcp_support` branch during implementation.

---

## 🌳 Branch Overview

**Main Branch**: `main` (stable, Azure-only, current production)  
**Feature Branch**: `aws_gcp_support` (development, multi-cloud support)

---

## 🚀 Getting Started

### Initial Setup (Already Done)

```bash
# Create and switch to feature branch
git checkout -b aws_gcp_support

# Add planning documents (already committed)
git add MULTI_CLOUD_SUPPORT_PLAN.md
git add VALIDATION_CHECKLIST.md
git add EFFORT_ESTIMATION.md
git add QUICK_START_GUIDE.md
git add config.example.sh
git add README_MULTI_CLOUD.md
git add GIT_WORKFLOW.md

git commit -m "docs: add multi-cloud support planning documents"
```

### Push to Remote

```bash
# Push feature branch to remote
git push -u origin aws_gcp_support
```

---

## 📋 Development Workflow

### Phase-Based Development

Each phase should be developed and committed separately for easier review and rollback.

#### Phase 1: Project Restructuring

```bash
# Make sure you're on the feature branch
git checkout aws_gcp_support

# Create new directory structure
mkdir -p providers/{azure,aws,gcp}
mkdir -p scripts common docs

# Move and update files
# ... (do your work)

# Stage changes
git add providers/
git add scripts/
git add config.sh

# Commit with descriptive message
git commit -m "refactor: restructure project for multi-cloud support (Phase 1)

- Created providers/{azure,aws,gcp} directories
- Moved existing Azure IaC to providers/azure/
- Updated config.sh with CLOUD_PROVIDER selection
- Updated script paths and references
- Tested: existing Azure deployment still works"

# Push to remote
git push origin aws_gcp_support
```

#### Phase 2: AWS Support

```bash
# Create AWS infrastructure
git add providers/aws/

# Commit incrementally
git commit -m "feat(aws): add EKS infrastructure with tag support (Phase 2)

- Created Terraform modules for EKS clusters
- Implemented VPC, subnets, security groups
- Added tag propagation for owner and skip_deletion
- Created get-credentials.sh wrapper
- Tested: EKS clusters deploy successfully with all tags"

git push origin aws_gcp_support
```

#### Phase 3: GCP Support

```bash
# Create GCP infrastructure
git add providers/gcp/

git commit -m "feat(gcp): add GKE infrastructure with label support (Phase 3)

- Created Terraform modules for GKE clusters
- Implemented VPC, node pools
- Added label propagation for owner and skip_deletion
- Created get-credentials.sh wrapper
- Tested: GKE clusters deploy successfully with all labels"

git push origin aws_gcp_support
```

#### Phases 4-6

Follow the same pattern: implement, test, commit with descriptive messages, push.

---

## 🔄 Keeping Branch Updated

### Sync with Main Branch

If `main` branch receives updates while you're working:

```bash
# Switch to main and pull latest
git checkout main
git pull origin main

# Switch back to feature branch
git checkout aws_gcp_support

# Rebase feature branch on latest main
git rebase main

# If conflicts occur:
# 1. Resolve conflicts in files
# 2. git add <resolved-files>
# 3. git rebase --continue

# Force push (rebase rewrites history)
git push -f origin aws_gcp_support
```

**Alternative: Merge Strategy** (safer if branch is shared)

```bash
git checkout aws_gcp_support
git merge main

# Resolve conflicts if any
git commit -m "merge: sync with main branch"
git push origin aws_gcp_support
```

---

## ✅ Testing Before Merge

### Pre-Merge Validation

Before merging to `main`, verify all phases are complete:

```bash
# On aws_gcp_support branch

# 1. Review checklist
cat VALIDATION_CHECKLIST.md

# 2. Run full test suite
./scripts/check-tags.sh  # For current cloud provider

# 3. Test each cloud provider
CLOUD_PROVIDER=azure ./scripts/create-all.sh
# Verify, then cleanup
./scripts/delete-all-resources.sh

CLOUD_PROVIDER=aws ./scripts/create-all.sh
# Verify, then cleanup
./scripts/delete-all-resources.sh

CLOUD_PROVIDER=gcp ./scripts/create-all.sh
# Verify, then cleanup
./scripts/delete-all-resources.sh

# 4. Verify backward compatibility
# Switch to old config format and verify Azure still works
```

---

## 🔀 Merging to Main

### Create Pull Request

```bash
# Make sure feature branch is up to date
git checkout aws_gcp_support
git pull origin aws_gcp_support

# Push latest changes
git push origin aws_gcp_support

# Create PR via GitHub/GitLab web interface or CLI
gh pr create --title "Multi-Cloud Support: AWS & GCP" \
  --body "Implements support for deploying Redis Enterprise Active/Active on AWS (EKS) and GCP (GKE) in addition to Azure (AKS).

## Changes
- ✅ Restructured project for multi-cloud support
- ✅ Added AWS/EKS infrastructure with full tag support
- ✅ Added GCP/GKE infrastructure with full label support
- ✅ Unified config.sh for all cloud providers
- ✅ Updated all scripts to detect and use appropriate cloud provider
- ✅ Enhanced tag/label validation
- ✅ Complete documentation

## Testing
- [x] Azure deployment works
- [x] AWS deployment works
- [x] GCP deployment works
- [x] All resources properly tagged/labeled
- [x] Chaos tests pass on all clouds
- [x] Full cleanup verified

See VALIDATION_CHECKLIST.md for complete test results."
```

### Merge Strategies

**Option 1: Squash Merge** (cleaner history)

```bash
# Via GitHub: "Squash and merge" button
# Or via command line:
git checkout main
git merge --squash aws_gcp_support
git commit -m "feat: add multi-cloud support for AWS and GCP

Implements Redis Enterprise Active/Active deployment on:
- Azure AKS (existing + refactored)
- AWS EKS (new)
- GCP GKE (new)

All resources tagged/labeled with owner and skip_deletion.

Closes #123"
git push origin main
```

**Option 2: Merge Commit** (preserves history)

```bash
git checkout main
git merge --no-ff aws_gcp_support -m "Merge multi-cloud support"
git push origin main
```

### Post-Merge Cleanup

```bash
# Delete remote feature branch
git push origin --delete aws_gcp_support

# Delete local feature branch
git branch -d aws_gcp_support

# Or keep it for reference
git branch -m aws_gcp_support aws_gcp_support-merged
```

---

## 🏷️ Tagging Releases

### Version Tagging Strategy

```bash
# After merging to main
git checkout main
git pull origin main

# Tag the release
git tag -a v2.0.0 -m "Release v2.0.0: Multi-Cloud Support

Features:
- Azure AKS support (refactored)
- AWS EKS support (new)
- GCP GKE support (new)
- Unified configuration
- Enhanced tag/label validation"

# Push tag
git push origin v2.0.0
```

### Suggested Version Scheme

- `v1.x.x` - Azure-only versions (current main)
- `v2.0.0` - Multi-cloud support (Phase 1 complete)
- `v2.1.0` - AWS support added
- `v2.2.0` - GCP support added
- `v2.3.0` - Additional features/improvements

---

## 🔧 Troubleshooting

### Accidentally Committed to Main

```bash
# If you haven't pushed yet
git log  # Find commit hash to undo
git reset --hard <hash-before-your-commits>

# If you already pushed (dangerous!)
# Contact team before force pushing to main
```

### Lost Changes

```bash
# View all commits (even deleted ones)
git reflog

# Recover lost commit
git checkout <commit-hash>
git checkout -b recovery-branch
```

### Merge Conflicts

```bash
# During merge/rebase, if conflicts occur:

# 1. View conflicted files
git status

# 2. Edit files to resolve conflicts
# Look for markers: <<<<<<<, =======, >>>>>>>

# 3. Mark as resolved
git add <resolved-file>

# 4. Continue merge/rebase
git merge --continue
# or
git rebase --continue
```

---

## 📊 Useful Git Commands

### Viewing History

```bash
# Compact one-line view
git log --oneline --graph --decorate --all

# View changes in a file
git log -p -- path/to/file

# View commits by author
git log --author="Thomas"
```

### Comparing Branches

```bash
# See what's different
git diff main..aws_gcp_support

# See list of changed files
git diff --name-only main..aws_gcp_support

# See commit differences
git log main..aws_gcp_support
```

### Undoing Changes

```bash
# Undo last commit (keep changes)
git reset --soft HEAD~1

# Undo last commit (discard changes)
git reset --hard HEAD~1

# Undo changes to a file
git checkout -- path/to/file
```

---

## 📝 Commit Message Convention

Follow this format for consistency:

```
<type>(<scope>): <subject>

<body>

<footer>
```

**Types**:
- `feat`: New feature
- `fix`: Bug fix
- `docs`: Documentation changes
- `refactor`: Code restructuring
- `test`: Adding tests
- `chore`: Maintenance tasks

**Examples**:

```
feat(aws): add EKS cluster provisioning with tags

- Implemented VPC and subnet configuration
- Added EKS cluster resources with node groups
- Ensured all resources tagged with owner and skip_deletion

Closes #42
```

```
docs: update multi-cloud deployment guide

Added AWS-specific setup instructions and troubleshooting
```

---

**Document Version**: 1.0  
**Last Updated**: 2026-05-04  
**Branch**: aws_gcp_support
