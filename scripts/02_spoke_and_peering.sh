#!/usr/bin/env bash
set -euo pipefail

RG_NAME="rg-fgt-hubspoke"
LOCATION="westeurope"

HUB_VNET_NAME="vnet-hub-fgt"

SPOKE_VNET_NAME="vnet-spoke-app"
SPOKE_VNET_CIDR="10.101.0.0/16"
SPOKE_SUBNET_NAME="snet-spoke-app"
SPOKE_SUBNET_CIDR="10.101.1.0/24"

ROUTE_TABLE_NAME="rt-spoke-via-fgt"
FGT_LAN_IP="10.100.1.4"

WORKLOAD_VM_NAME="vm-spoke-app-01"
WORKLOAD_ADMIN_USER="labadmin"
WORKLOAD_ADMIN_PASSWORD="LabNet!2025xY"

echo "[01] Spoke VNet + subnet"
if ! az network vnet show -g "$RG_NAME" -n "$SPOKE_VNET_NAME" >/dev/null 2>&1; then
  az network vnet create \
    -g "$RG_NAME" \
    -n "$SPOKE_VNET_NAME" \
    -l "$LOCATION" \
    --address-prefixes "$SPOKE_VNET_CIDR" \
    --subnet-name "$SPOKE_SUBNET_NAME" \
    --subnet-prefixes "$SPOKE_SUBNET_CIDR" \
    --only-show-errors >/dev/null
fi

echo "[02] Workload NIC"
if ! az network nic show -g "$RG_NAME" -n "nic-spoke-app-01" >/dev/null 2>&1; then
  az network nic create \
    -g "$RG_NAME" \
    -n "nic-spoke-app-01" \
    --vnet-name "$SPOKE_VNET_NAME" \
    --subnet "$SPOKE_SUBNET_NAME" \
    --only-show-errors >/dev/null
fi

echo "[03] Workload VM"
if ! az vm show -g "$RG_NAME" -n "$WORKLOAD_VM_NAME" >/dev/null 2>&1; then
  az vm create \
    -g "$RG_NAME" \
    -n "$WORKLOAD_VM_NAME" \
    --image Ubuntu2204 \
    --size Standard_B1s \
    --admin-username "$WORKLOAD_ADMIN_USER" \
    --admin-password "$WORKLOAD_ADMIN_PASSWORD" \
    --nics "nic-spoke-app-01" \
    --os-disk-size-gb 30 \
    --storage-sku StandardSSD_LRS \
    --only-show-errors >/dev/null
fi

echo "[04] Peering hub <-> spoke"
HUB_VNET_ID=$(az network vnet show -g "$RG_NAME" -n "$HUB_VNET_NAME" --query id -o tsv)
SPOKE_VNET_ID=$(az network vnet show -g "$RG_NAME" -n "$SPOKE_VNET_NAME" --query id -o tsv)

if ! az network vnet peering show -g "$RG_NAME" --vnet-name "$HUB_VNET_NAME" -n "hub-to-spoke" >/dev/null 2>&1; then
  az network vnet peering create \
    -g "$RG_NAME" \
    --vnet-name "$HUB_VNET_NAME" \
    -n "hub-to-spoke" \
    --remote-vnet "$SPOKE_VNET_ID" \
    --allow-vnet-access \
    --allow-forwarded-traffic \
    --only-show-errors >/dev/null
fi

if ! az network vnet peering show -g "$RG_NAME" --vnet-name "$SPOKE_VNET_NAME" -n "spoke-to-hub" >/dev/null 2>&1; then
  az network vnet peering create \
    -g "$RG_NAME" \
    --vnet-name "$SPOKE_VNET_NAME" \
    -n "spoke-to-hub" \
    --remote-vnet "$HUB_VNET_ID" \
    --allow-vnet-access \
    --allow-forwarded-traffic \
    --only-show-errors >/dev/null
fi

echo "[05] UDR via FortiGate"
if ! az network route-table show -g "$RG_NAME" -n "$ROUTE_TABLE_NAME" >/dev/null 2>&1; then
  az network route-table create \
    -g "$RG_NAME" \
    -n "$ROUTE_TABLE_NAME" \
    -l "$LOCATION" \
    --only-show-errors >/dev/null
fi

if ! az network route-table route show -g "$RG_NAME" --route-table-name "$ROUTE_TABLE_NAME" -n "default-via-fgt" >/dev/null 2>&1; then
  az network route-table route create \
    -g "$RG_NAME" \
    --route-table-name "$ROUTE_TABLE_NAME" \
    -n "default-via-fgt" \
    --address-prefix "0.0.0.0/0" \
    --next-hop-type VirtualAppliance \
    --next-hop-ip-address "$FGT_LAN_IP" \
    --only-show-errors >/dev/null
fi

az network vnet subnet update \
  -g "$RG_NAME" \
  --vnet-name "$SPOKE_VNET_NAME" \
  -n "$SPOKE_SUBNET_NAME" \
  --route-table "$ROUTE_TABLE_NAME" \
  --only-show-errors >/dev/null

WORKLOAD_IP=$(az vm list-ip-addresses -g "$RG_NAME" -n "$WORKLOAD_VM_NAME" --query "[0].virtualMachine.network.privateIpAddresses[0]" -o tsv)

echo
echo "=== SPOKE READY ==="
echo "Spoke VNet:   $SPOKE_VNET_NAME ($SPOKE_VNET_CIDR)"
echo "Workload VM:  $WORKLOAD_VM_NAME"
echo "  IP:         $WORKLOAD_IP"
echo "  User:       $WORKLOAD_ADMIN_USER"
echo "  Pass:       $WORKLOAD_ADMIN_PASSWORD"
