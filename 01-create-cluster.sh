#!/usr/bin/env bash
. ./config.sh
tofu init
TF_VAR_subscription_id=$(az account show --query id -o tsv)
TF_VAR_azure_rg=$RESOURCE_GROUP
export TF_VAR_subscription_id TF_VAR_azure_rg
tofu apply -auto-approve