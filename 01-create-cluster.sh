#!/bin/bash

tofu init
TOFU_VAR_subscription_id=$(az account show --query id -o tsv)  tofu apply -auto-approve