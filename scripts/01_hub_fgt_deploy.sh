#!/usr/bin/env bash
set -euo pipefail

# Hub + FortiGate deployment (idempotent)

RG_NAME="rg-fgt-hubspoke"
LOCATION="westeurope"

HUB_VNET_NAME="vnet-hub-fgt"
HUB_VNET_CIDR="10.100.0.0/16"

SUBNET_FW_WAN="snet-fw-wan"
SUBNET_FW_WAN_CIDR="10.100.0.0/24"

SUBNET_FW_LAN="snet-fw-lan"
SUBNET_FW_LAN_CIDR="10.100.1.0/24"

PIP_NAME="pip-fgt-hub"
FGT_VM_NAME="vm-fgt-hub"

FGT_LAN_IP="10.100.1.4"

FGT_ADMIN_USER="fortiadmin"
FGT_ADMIN_PASSWORD="Forti@12345Lab!"

# FortiGate PAYG image (you must have marketplace terms accepted for this image)
FGT_IMAGE="fortinet:fortinet_fortigate-vm_v5:fortinet_fg-vm_payg_2023:latest"

echo "[01] Resource group"
az group create -n "$RG_NAME" -l "$LOCATION" --only-show-errors >/dev/null

echo "[02] Hub VNet + subnets"
if ! az network vnet show -g "$RG_NAME" -n "$HUB_VNET_NAME" >/dev/null 2>&1; then
  az network vnet create \
    -g "$RG_NAME" \
    -n "$HUB_VNET_NAME" \
    -l "$LOCATION" \
    --address-prefixes "$HUB_VNET_CIDR" \
    --subnet-name "$SUBNET_FW_WAN" \
    --subnet-prefixes "$SUBNET_FW_WAN_CIDR" \
    --only-show-errors >/dev/null
fi

if ! az network vnet subnet show -g "$RG_NAME" --vnet-name "$HUB_VNET_NAME" -n "$SUBNET_FW_LAN" >/dev/null 2>&1; then
  az network vnet subnet create \
    -g "$RG_NAME" \
    --vnet-name "$HUB_VNET_NAME" \
    -n "$SUBNET_FW_LAN" \
    --address-prefixes "$SUBNET_FW_LAN_CIDR" \
    --only-show-errors >/dev/null
fi

echo "[03] Public IP"
az network public-ip create \
  -g "$RG_NAME" \
  -n "$PIP_NAME" \
  --sku Standard \
  --allocation-method Static \
  --version IPv4 \
  --only-show-errors >/dev/null

echo "[04] WAN NIC"
if ! az network nic show -g "$RG_NAME" -n "nic-fgt-wan" >/dev/null 2>&1; then
  az network nic create \
    -g "$RG_NAME" \
    -n "nic-fgt-wan" \
    --vnet-name "$HUB_VNET_NAME" \
    --subnet "$SUBNET_FW_WAN" \
    --public-ip-address "$PIP_NAME" \
    --ip-forwarding true \
    --only-show-errors >/dev/null
fi

echo "[05] LAN NIC"
if ! az network nic show -g "$RG_NAME" -n "nic-fgt-lan" >/dev/null 2>&1; then
  az network nic create \
    -g "$RG_NAME" \
    -n "nic-fgt-lan" \
    --vnet-name "$HUB_VNET_NAME" \
    --subnet "$SUBNET_FW_LAN" \
    --private-ip-address "$FGT_LAN_IP" \
    --ip-forwarding true \
    --only-show-errors >/dev/null
fi

echo "[06] FortiGate VM"
if ! az vm show -g "$RG_NAME" -n "$FGT_VM_NAME" >/dev/null 2>&1; then
  az vm create \
    -g "$RG_NAME" \
    -n "$FGT_VM_NAME" \
    --image "$FGT_IMAGE" \
    --size Standard_F4s_v2 \
    --admin-username "$FGT_ADMIN_USER" \
    --admin-password "$FGT_ADMIN_PASSWORD" \
    --nics "nic-fgt-wan" "nic-fgt-lan" \
    --os-disk-size-gb 60 \
    --storage-sku StandardSSD_LRS \
    --only-show-errors >/dev/null
fi

FGT_PIP=$(az network public-ip show -g "$RG_NAME" -n "$PIP_NAME" --query "ipAddress" -o tsv)

echo
echo "=== HUB + FGT READY ==="
echo "RG:        $RG_NAME"
echo "Hub VNet:  $HUB_VNET_NAME ($HUB_VNET_CIDR)"
echo "FGT VM:    $FGT_VM_NAME"
echo "  User:    $FGT_ADMIN_USER"
echo "  Pass:    $FGT_ADMIN_PASSWORD"
echo "  LAN IP:  $FGT_LAN_IP"
echo "  PIP:     $FGT_PIP"
