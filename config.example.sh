#!/usr/bin/env bash
# shellcheck disable=SC2034  # values are consumed by other scripts and by Terraform
# ============================================================================
# Multi-Cloud Redis Enterprise Active/Active — SINGLE SOURCE OF CONFIGURATION
# ============================================================================
# Copy to config.sh and edit:   cp config.example.sh config.sh
#
# RULE: every value Terraform needs lives HERE. There are no .tfvars files and
# no defaults in providers/*/variables.tf — config.sh is passed through as
# TF_VAR_* by common/lib.sh (re_export_tf_vars). If a value is missing the
# deployment fails loudly instead of silently using a different one.
#
# This file is SOURCED, never executed. Keep it declarative.
# ============================================================================

# ============================================================================
# Cloud provider selection
# ============================================================================
# azure | aws | gcp
CLOUD_PROVIDER=gcp

# ============================================================================
# Common — applies to every provider
# ============================================================================

# Cluster name prefix. Cluster names are derived: <prefix>-<region>
#
# MUST be unique per operator when the cloud project is shared. All resource
# names derive from it (VPC, subnets, firewalls, clusters, node pools), so a
# generic value like "redis" collides with other people's deployments in the
# same project — and Terraform does NOT adopt what it did not create, it just
# fails with 409 alreadyExists.
#
# Keep it short: the GKE cluster and node-pool names are capped at 40 chars and
# are built as <prefix>-<region>-nodes. ./gcp-deploy.sh validates this.
CLUSTER_PREFIX=redis-<yourname>-aa

# ── Cluster identity: TWO namespaces, deliberately decoupled ────────────────
# CLUSTER_PREFIX below names the CLOUD resources (VPC, subnets, firewalls, GKE
# clusters). It must be unique per operator on a shared project, so it carries
# your name — and GCP cannot label networks, so the name IS the attribution
# (docs/adr/0006).
#
# But that name also ended up in every DNS record and Redis Enterprise cluster
# name, giving endpoints like
#     active-active-db-db.redis-t-manson-aa-us-central1.gcp.paquerette.com
# which is long, leaks the operator's name to anyone resolving it, and repeats
# the region. These aliases keep the PUBLIC identity short and neutral:
#     <db>-db.rec-a.gcp.paquerette.com
RE_ALIAS1=a
RE_ALIAS2=b

# Kubernetes namespace for the Redis Enterprise resources
NS=rec

# ── Redis Enterprise cluster sizing (was hardcoded in templates/rec.yaml) ────
# One RE node per availability zone, so RE_NODES should match the number of
# zones. Each must fit on one worker node: a n1-standard-8 is 8 vCPU / 30 GB,
# so 4 CPU + 16 GB leaves room for system pods.
RE_NODES=3
RE_CPU=4000m
RE_MEMORY=16Gi

# ── Active/Active database sizing (was hardcoded in templates/re-aa-db.yaml) ─
AA_DB_MEMORY=200MB
AA_DB_SHARDS=1

# ── Node topology: ONE Redis Enterprise node per availability zone ──────────
# The REC (templates/rec.yaml) asks for `nodes: 3`, so we want 3 worker nodes
# per cluster, one in each of 3 zones. That is what makes the zonal-outage
# demo credible.
#
# ⚠️  Each cloud counts nodes DIFFERENTLY, so express the INTENT here and let
#    common/lib.sh translate it per provider:
#      GKE (regional) : node_count is PER ZONE      -> 1
#      AKS            : node_count is the TOTAL     -> 1 x 3 = 3
#      EKS            : desired_size is the TOTAL   -> 1 x 3 = 3
#    Getting this wrong is expensive: node_count=3 on a regional GKE cluster
#    means 3 x 3 zones = 9 nodes per region, 18 in total.
NODES_PER_ZONE=1

# Redis Enterprise Cluster Manager UI session timeout, in MINUTES.
# The cluster default is 15 min, which logs you out mid-demo. Applied by
# step 03 via  PUT /v1/cluster  {"cm_session_timeout_minutes": N}.
RE_UI_SESSION_TIMEOUT_MINUTES=1440

# Active/Active database name.
# Must match ^[a-z]($|[a-z0-9-]*[a-z0-9])$
# Do NOT end it with "db": the Redis Enterprise dbFqdnSuffix already appends
# "-db", so "active-active-db" produced "active-active-db-db.<suffix>".
AA_DB_NAME=aadb

# NOTE: the DNS zone is per-cloud (see <CLOUD>_DNS_ZONE below). Each cloud
# needs its own managed zone, otherwise two simultaneous demos would fight over
# the same '*.<cluster>' records. The generic DNS_ZONE is derived at the bottom.

# Owner tag/label — format: firstname_lastname (lowercase). Enforced on all
# three clouds. Used for cost attribution and by check-tags.sh.
owner=firstname_lastname

# Skip-deletion tag/label: yes | no. Advisory — protects against external
# reapers, NOT against ./delete-all-resources.sh.
skip_deletion=yes

# ============================================================================
# Azure (AKS)
# ============================================================================
# Resource group for the AKS clusters (disposable)
AZURE_CLUSTER_RESOURCE_GROUP=MyName-temp-AKS
# Resource group holding the DNS zone (permanent — kept out of teardown)
AZURE_DNS_RESOURCE_GROUP=MyName
AZURE_REGION1=francecentral
AZURE_REGION2=ukwest
AZURE_INSTANCE_TYPE=Standard_D8s_v3
# AKS availability zones, comma-separated (AKS names them 1/2/3, not by region).
AZURE_ZONES=1,2,3
# TOTAL for the pool (AKS spreads it across AZURE_ZONES) -> 1 per zone x 3.
AZURE_NODE_COUNT=3
AZURE_DNS_PREFIX=redis
AZURE_NETWORK_PLUGIN=kubenet
AZURE_LOAD_BALANCER_SKU=standard
# Azure DNS zone (must live in AZURE_DNS_RESOURCE_GROUP, i.e. NOT in the
# cluster resource group, so teardown never destroys it).
AZURE_DNS_ZONE=azure.example.com
# Note: the Azure subscription ID is read from your `az` session at deploy
# time, not stored here.

# ============================================================================
# AWS (EKS)
# ============================================================================
# AWS has no resource groups; this value is applied as a tag.
AWS_CLUSTER_RESOURCE_GROUP=MyName-temp-EKS
AWS_REGION1=us-east-1
AWS_REGION2=us-west-2
AWS_INSTANCE_TYPE=m5.2xlarge
# Kubernetes version. Must be in EKS standard support AND supported by the
# Redis Enterprise operator (8.2.x supports 1.33-1.36).
AWS_EKS_VERSION=1.36
# Number of availability zones to spread across (one subnet pair per AZ).
AWS_AZ_COUNT=3
# TOTAL across all AZs (EKS balances the node group) -> 1 per zone x 3.
AWS_NODE_DESIRED_SIZE=3
AWS_NODE_MIN_SIZE=3
AWS_NODE_MAX_SIZE=6
# One VPC per region. The two CIDRs must not overlap.
AWS_VPC_CIDR1=10.0.0.0/16
AWS_VPC_CIDR2=10.1.0.0/16
# Route53 hosted zone.
AWS_DNS_ZONE=aws.example.com

# ============================================================================
# GCP (GKE)
# ============================================================================
GCP_PROJECT_ID=my-redis-project

# ── GCP authentication: THREE credentials can be in play ────────────────────
# 1. GOOGLE_APPLICATION_CREDENTIALS (env var -> a service-account key file)
#    WINS over everything for client libraries, including the OpenTofu google
#    provider. If it is set, THAT identity creates the clusters. Note that
#    `gcloud auth application-default login` does NOT override it — gcloud even
#    warns you about this. Check with:  echo $GOOGLE_APPLICATION_CREDENTIALS
# 2. Application Default Credentials (~/.config/gcloud/application_default_
#    credentials.json) — used by OpenTofu only when (1) is unset.
# 3. The gcloud CLI account (GCP_ACCOUNT below) — used by gcloud commands:
#    kubeconfig (providers/gcp/get-credentials.sh) and DNS (common/dns-gcp.sh).
# (1)/(2) and (3) are INDEPENDENT: `tofu plan` can succeed while every gcloud
# call returns 403, and vice versa. ./gcp-deploy.sh --plan-only reports all of
# them. To use a single identity for everything:
#    gcloud auth activate-service-account --key-file="$GOOGLE_APPLICATION_CREDENTIALS"
#    # then set GCP_ACCOUNT to that service account's client_email

# Which credentialed gcloud account to use for THIS project.
# Leave empty to auto-detect from `gcloud auth list` (the deploy script probes
# each credentialed account against the project and picks the first that can
# actually see it). Set it explicitly when you have several accounts — e.g. a
# work account and a personal one — to avoid deploying with the wrong identity.
#   gcloud auth list          # see what is available
# The scripts NEVER run `gcloud config set account`: they export
# CLOUDSDK_CORE_ACCOUNT for their own process only, so your global gcloud
# state and other terminals are untouched.
GCP_ACCOUNT=
GCP_REGION1=us-central1
GCP_REGION2=europe-west1
GCP_INSTANCE_TYPE=n1-standard-8
# Zones for each region, comma-separated. These become the cluster's
# node_locations, so the spread is explicit instead of left to GKE's default.
#   gcloud compute zones list --filter="region~/<region>$" --format='value(name)'
GCP_ZONES1=us-central1-a,us-central1-b,us-central1-c
GCP_ZONES2=europe-west1-b,europe-west1-c,europe-west1-d
# PER ZONE on a regional cluster (see NODES_PER_ZONE above).
GCP_NODE_COUNT=1
GCP_NODE_MIN_COUNT=1
GCP_NODE_MAX_COUNT=2
# GKE release channel: RAPID | REGULAR | STABLE. A channel, not a version pin —
# GKE tracks a recent Kubernetes release automatically.
GCP_RELEASE_CHANNEL=REGULAR
# Subnet CIDRs (primary) plus secondary ranges for pods and services.
GCP_SUBNET_CIDR1=10.0.0.0/20
GCP_PODS_CIDR1=10.0.16.0/20
GCP_SERVICES_CIDR1=10.0.32.0/20
GCP_SUBNET_CIDR2=10.1.0.0/20
GCP_PODS_CIDR2=10.1.16.0/20
GCP_SERVICES_CIDR2=10.1.32.0/20
# ── Terraform operation timeouts ────────────────────────────────────────────
# The google provider defaults GKE cluster/node-pool operations to 40 minutes.
# Measured in this project, node-pool operations regularly EXCEED that:
#   CREATE_NODE_POOL 35m30, DELETE_NODE_POOL 1h01 (x2), UPGRADE_NODES 1h14.
# A 40-minute cap therefore aborts runs that GCP would have completed — and the
# error Terraform reports is the last failed poll, which looks like a DNS
# problem and hides the real cause. Give it real headroom.
GCP_CLUSTER_TIMEOUT=90m   # the node pool is now created INSIDE the cluster operation: it needs the old pool headroom too

# Ports opened for Redis Enterprise. Comma-separated, Terraform list syntax.
#   8443  = Redis Enterprise UI/API via ingress
#   10000-19999 = database endpoints
# The demo requires reachability from anywhere (see docs/adr/0010), so these
# are internet-facing by design; security is enforced by TLS + password + ACLs.
# 8001 (Redis Insight) and 9443 (internal operator) are deliberately NOT here.
# Cloud DNS managed zone in GCP_PROJECT_ID. Check what you have with:
#   gcloud dns managed-zones list --project <project>
GCP_DNS_ZONE=gcp.example.com

GCP_REDIS_PORTS='["8443","10000-19999"]'

# Service account the GKE NODES run as: dedicated and least-privilege, NOT the
# Compute Engine default SA (project Editor). It must exist before the deploy;
# the commands to create it are in docs/gcp-iam.md. Format:
#   gke-nodes@<GCP_PROJECT_ID>.iam.gserviceaccount.com
GCP_NODE_SERVICE_ACCOUNT=gke-nodes@your-project-id.iam.gserviceaccount.com

# Project roles the DEPLOY identity (GCP_ACCOUNT) needs. Granted by ./gcp-setup.sh
# (run once, as an IAM admin, before ./gcp-deploy.sh). Space-separated. Why each
# one: docs/gcp-iam.md §3. Never add IAM-admin / owner / editor roles here.
GCP_DEPLOYER_ROLES="roles/compute.admin roles/container.admin roles/dns.admin roles/cloudasset.viewer"

# APIs ./gcp-setup.sh enables on the project (idempotent). cloudasset serves the
# label-wide audit in ./check-tags.sh; the others are needed to deploy.
GCP_REQUIRED_APIS="container.googleapis.com compute.googleapis.com dns.googleapis.com cloudasset.googleapis.com"

# Who runs ./gcp-setup.sh (an account WITH IAM rights, never GCP_ACCOUNT).
# Leave empty to use the currently active gcloud account.
GCP_ADMIN_ACCOUNT=

# ── Terraform concurrency ───────────────────────────────────────────────────
# Terraform runs 10 operations in parallel by default. Each keeps its own TLS
# connections and polling loop, and macOS defaults to `ulimit -n` 256 — when
# the resolver can no longer open a socket, Go reports "no such host", which
# masquerades as a DNS outage. The scripts also raise the fd limit for
# themselves; this caps the demand.
TF_PARALLELISM=4

# ============================================================================
# Provider aliases — generic names used by the shell scripts
# ============================================================================
case $CLOUD_PROVIDER in
  azure)
    CLUSTER_RESOURCE_GROUP=$AZURE_CLUSTER_RESOURCE_GROUP
    DNS_RESOURCE_GROUP=$AZURE_DNS_RESOURCE_GROUP
    REGION1=$AZURE_REGION1
    REGION2=$AZURE_REGION2
    INSTANCE_TYPE=$AZURE_INSTANCE_TYPE
    DNS_ZONE=$AZURE_DNS_ZONE
    ;;
  aws)
    CLUSTER_RESOURCE_GROUP=$AWS_CLUSTER_RESOURCE_GROUP
    DNS_RESOURCE_GROUP=$AWS_CLUSTER_RESOURCE_GROUP
    REGION1=$AWS_REGION1
    REGION2=$AWS_REGION2
    INSTANCE_TYPE=$AWS_INSTANCE_TYPE
    DNS_ZONE=$AWS_DNS_ZONE
    ;;
  gcp)
    CLUSTER_RESOURCE_GROUP=$GCP_PROJECT_ID
    DNS_RESOURCE_GROUP=$GCP_PROJECT_ID
    REGION1=$GCP_REGION1
    REGION2=$GCP_REGION2
    INSTANCE_TYPE=$GCP_INSTANCE_TYPE
    DNS_ZONE=$GCP_DNS_ZONE
    ;;
  *)
    echo "❌ ERROR: invalid CLOUD_PROVIDER '$CLOUD_PROVIDER' (azure, aws or gcp)" >&2
    # `return` when sourced (the normal case); `exit` only if executed directly.
    return 1 2>/dev/null || exit 1
    ;;
esac

# Derived cluster names — kubectl context names match these.
CLUSTER1=${CLUSTER_PREFIX}-${REGION1}
CLUSTER2=${CLUSTER_PREFIX}-${REGION2}
# Optional third cluster: read by the test tooling only, ignored by the
# deployment pipeline. Leave empty.
CLUSTER3=

# ── Public / Redis Enterprise identity, derived from the aliases ─────────────
# REC_NAME<n> names the RedisEnterpriseCluster object and every FQDN:
#     api.<REC_NAME>.<DNS_ZONE>        REST API + Cluster Manager UI
#     <AA_DB_NAME>-db.<REC_NAME>.<DNS_ZONE>   database endpoint
# Kept independent of CLUSTER_PREFIX on purpose (see above).
REC_NAME1=rec-${RE_ALIAS1}
REC_NAME2=rec-${RE_ALIAS2}

echo "✅ Configuration loaded"
echo "   Cloud Provider : $CLOUD_PROVIDER"
echo "   Cluster 1      : $CLUSTER1 (region: $REGION1)"
echo "   Cluster 2      : $CLUSTER2 (region: $REGION2)"
echo "   Instance type  : $INSTANCE_TYPE"
echo "   DNS zone       : $DNS_ZONE"
echo "   Owner          : $owner   Skip deletion: $skip_deletion"
