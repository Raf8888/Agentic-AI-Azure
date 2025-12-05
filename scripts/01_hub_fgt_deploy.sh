#!/usr/bin/env bash
set -euo pipefail

#############################################
# Azure FortiGate Hub Deployment Script
# Fully idempotent — safe to rerun
#############################################

# ==== CONFIGURATION ====
RG_NAME="rg-fgt-hubspoke"
LOCATION="westeurope"

HUB_VNET_NAME="vnet-hub-fgt"
HUB_VNET_CIDR="10.0.0.0/24"

SUBNET_FW_WAN="subnet-fw-wan"
SUBNET_FW_WAN_CIDR="10.0.0.0/28"

SUBNET_FW_LAN="subnet-fw-lan"
SUBNET_FW_LAN_CIDR="10.0.0.16/28"

PIP_NAME="pip-fgt-hub"
FGT_VM_NAME="fgt-hub"

FGT_LAN_IP="10.0.0.20"

IMAGE_PUBLISHER="fortinet"
IMAGE_OFFER="fortinet_fortigate-vm_v5"
IMAGE_SKU="fortinet_fg-vm_payg_2023"
IMAGE_VERSION="latest"

#############################################
echo "[INFO] Ensuring resource group $RG_NAME"
az group create --name "$RG_NAME" --location "$LOCATION" --only-show-errors

#############################################
echo "[INFO] Ensuring VNet $HUB_VNET_NAME with subnets"
if ! az network vnet show --resource-group "$RG_NAME" --name "$HUB_VNET_NAME" >/dev/null 2>&1; then
  az network vnet create \
    --resource-group "$RG_NAME" \
    --name "$HUB_VNET_NAME" \
    --location "$LOCATION" \
    --address-prefix "$HUB_VNET_CIDR" \
    --subnet-name "$SUBNET_FW_WAN" \
    --subnet-prefix "$SUBNET_FW_WAN_CIDR" \
    --only-show-errors
fi

# Ensure LAN subnet exists
if ! az network vnet subnet show --resource-group "$RG_NAME" --vnet-name "$HUB_VNET_NAME" --name "$SUBNET_FW_LAN" >/dev/null 2>&1; then
  az network vnet subnet create \
    --resource-group "$RG_NAME" \
    --vnet-name "$HUB_VNET_NAME" \
    --name "$SUBNET_FW_LAN" \
    --address-prefix "$SUBNET_FW_LAN_CIDR" \
    --only-show-errors
fi

#############################################
echo "[INFO] Ensuring public IP $PIP_NAME"
az network public-ip create \
  --resource-group "$RG_NAME" \
  --name "$PIP_NAME" \
  --version IPv4 \
  --sku Standard \
  --allocation-method Static \
  --only-show-errors

#############################################
echo "[INFO] Ensuring WAN NIC nic-fgt-wan"
if ! az network nic show --resource-group "$RG_NAME" --name "nic-fgt-wan" >/dev/null 2>&1; then
  az network nic create \
    --resource-group "$RG_NAME" \
    --name "nic-fgt-wan" \
    --vnet-name "$HUB_VNET_NAME" \
    --subnet "$SUBNET_FW_WAN" \
    --public-ip-address "$PIP_NAME" \
    --ip-forwarding true \
    --only-show-errors
fi

#############################################
echo "[INFO] Ensuring LAN NIC nic-fgt-lan"
if ! az network nic show --resource-group "$RG_NAME" --name "nic-fgt-lan" >/dev/null 2>&1; then
  az network nic create \
    --resource-group "$RG_NAME" \
    --name "nic-fgt-lan" \
    --vnet-name "$HUB_VNET_NAME" \
    --subnet "$SUBNET_FW_LAN" \
    --private-ip-address "$FGT_LAN_IP" \
    --ip-forwarding true \
    --only-show-errors
fi

#############################################
echo "[INFO] Deploying FortiGate VM if not exists"
if ! az vm show --resource-group "$RG_NAME" --name "$FGT_VM_NAME" >/dev/null 2>&1; then
  az vm create \
    --resource-group "$RG_NAME" \
    --name "$FGT_VM_NAME" \
    --location "$LOCATION" \
    --size "Standard_F4s_v2" \
    --public-ip-address "" \
    --nics "nic-fgt-wan" "nic-fgt-lan" \
    --image "$IMAGE_PUBLISHER:$IMAGE_OFFER:$IMAGE_SKU:$IMAGE_VERSION" \
    --admin-username "adminuser" \
    --generate-ssh-keys \
    --only-show-errors
fi

#############################################
echo "[SUCCESS] Hub FortiGate deployment complete."
