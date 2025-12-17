#!/usr/bin/env bash
. ./config.sh
tofu init

TF_VAR_subscription_id=$(az account show --query id -o tsv)
TF_VAR_azure_rg=$CLUSTER_RESOURCE_GROUP
TF_VAR_owner=$owner
TF_VAR_skip_deletion=$skip_deletion

export TF_VAR_subscription_id TF_VAR_azure_rg TF_VAR_owner TF_VAR_skip_deletion
echo "tofu init done"
tofu apply -auto-approve
echo "tofu apply done"