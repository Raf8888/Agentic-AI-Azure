#!/usr/bin/env bash
set -euo pipefail

AZURE_REGION="${AZURE_REGION:-westeurope}"
RESOURCE_GROUP="rg-fgt-hubspoke"
HUB_VNET="vnet-hub-fgt"
SPOKE_VNET="vnet-spoke-app"
SPOKE_PREFIX="10.101.0.0/16"
SPOKE_SUBNET="snet-spoke-app"
SPOKE_SUBNET_PREFIX="10.101.1.0/24"
WORKLOAD_NIC="nic-spoke-app-01"
WORKLOAD_VM="vm-spoke-app-01"
WORKLOAD_ADMIN="labadmin"
WORKLOAD_PW="LabNet!2025xY"
ROUTE_TABLE="rt-spoke-via-fgt"
ROUTE_NAME="default-via-fgt"
FGT_LAN_IP="10.100.1.4"

log() { echo "[INFO] $*"; }

log "Ensuring spoke VNet $SPOKE_VNET and subnet $SPOKE_SUBNET"
if az network vnet show --only-show-errors -g "$RESOURCE_GROUP" -n "$SPOKE_VNET" >/dev/null 2>&1; then
  log "Spoke VNet $SPOKE_VNET already exists"
else
  az network vnet create --only-show-errors \
    -g "$RESOURCE_GROUP" -n "$SPOKE_VNET" \
    --location "$AZURE_REGION" \
    --address-prefixes "$SPOKE_PREFIX" \
    --subnet-name "$SPOKE_SUBNET" --subnet-prefixes "$SPOKE_SUBNET_PREFIX" >/dev/null
fi

log "Ensuring workload NIC $WORKLOAD_NIC"
if ! az network nic show --only-show-errors -g "$RESOURCE_GROUP" -n "$WORKLOAD_NIC" >/dev/null 2>&1; then
  az network nic create --only-show-errors \
    -g "$RESOURCE_GROUP" -n "$WORKLOAD_NIC" \
    --vnet-name "$SPOKE_VNET" --subnet "$SPOKE_SUBNET" >/dev/null
else
  log "NIC $WORKLOAD_NIC already exists"
fi

log "Ensuring workload VM $WORKLOAD_VM"
if az vm show --only-show-errors -g "$RESOURCE_GROUP" -n "$WORKLOAD_VM" >/dev/null 2>&1; then
  log "VM $WORKLOAD_VM already exists"
else
  az vm create --only-show-errors \
    -g "$RESOURCE_GROUP" -n "$WORKLOAD_VM" \
    --nics "$WORKLOAD_NIC" \
    --image Ubuntu2204 \
    --admin-username "$WORKLOAD_ADMIN" --admin-password "$WORKLOAD_PW" \
    --authentication-type password \
    --size Standard_B2s \
    --public-ip-address "" >/dev/null
fi

log "Configuring VNet peering between hub and spoke"
HUB_VNET_ID=$(az network vnet show --only-show-errors -g "$RESOURCE_GROUP" -n "$HUB_VNET" --query id -o tsv)
SPOKE_VNET_ID=$(az network vnet show --only-show-errors -g "$RESOURCE_GROUP" -n "$SPOKE_VNET" --query id -o tsv)

if ! az network vnet peering show --only-show-errors -g "$RESOURCE_GROUP" --vnet-name "$HUB_VNET" -n hub-to-spoke >/dev/null 2>&1; then
  az network vnet peering create --only-show-errors \
    -g "$RESOURCE_GROUP" --vnet-name "$HUB_VNET" \
    -n hub-to-spoke --remote-vnet "$SPOKE_VNET_ID" \
    --allow-vnet-access --allow-forwarded-traffic >/dev/null
else
  log "Peering hub-to-spoke already exists"
fi

if ! az network vnet peering show --only-show-errors -g "$RESOURCE_GROUP" --vnet-name "$SPOKE_VNET" -n spoke-to-hub >/dev/null 2>&1; then
  az network vnet peering create --only-show-errors \
    -g "$RESOURCE_GROUP" --vnet-name "$SPOKE_VNET" \
    -n spoke-to-hub --remote-vnet "$HUB_VNET_ID" \
    --allow-vnet-access --allow-forwarded-traffic >/dev/null
else
  log "Peering spoke-to-hub already exists"
fi

log "Ensuring route table $ROUTE_TABLE with default route via FortiGate"
if az network route-table show --only-show-errors -g "$RESOURCE_GROUP" -n "$ROUTE_TABLE" >/dev/null 2>&1; then
  log "Route table $ROUTE_TABLE already exists"
else
  az network route-table create --only-show-errors -g "$RESOURCE_GROUP" -n "$ROUTE_TABLE" --location "$AZURE_REGION" >/dev/null
fi

if az network route-table route show --only-show-errors -g "$RESOURCE_GROUP" --route-table-name "$ROUTE_TABLE" -n "$ROUTE_NAME" >/dev/null 2>&1; then
  log "Route $ROUTE_NAME already exists"
else
  az network route-table route create --only-show-errors \
    -g "$RESOURCE_GROUP" --route-table-name "$ROUTE_TABLE" \
    -n "$ROUTE_NAME" --address-prefix 0.0.0.0/0 \
    --next-hop-type VirtualAppliance --next-hop-ip-address "$FGT_LAN_IP" >/dev/null
fi

log "Associating route table $ROUTE_TABLE to subnet $SPOKE_SUBNET"
az network vnet subnet update --only-show-errors \
  -g "$RESOURCE_GROUP" --vnet-name "$SPOKE_VNET" -n "$SPOKE_SUBNET" \
  --route-table "$ROUTE_TABLE" >/dev/null

WORKLOAD_IP=$(az vm list-ip-addresses --only-show-errors -g "$RESOURCE_GROUP" -n "$WORKLOAD_VM" --query "[].virtualMachine.network.privateIpAddresses[0]" -o tsv)

log "Deployment summary"
echo "Spoke VNet: $SPOKE_VNET ($SPOKE_PREFIX)"
echo "Spoke subnet: $SPOKE_SUBNET ($SPOKE_SUBNET_PREFIX)"
echo "Workload VM: $WORKLOAD_VM private IP=${WORKLOAD_IP:-N/A}"
echo "Peering: hub-to-spoke and spoke-to-hub configured"
echo "Route table: $ROUTE_TABLE with route $ROUTE_NAME -> $FGT_LAN_IP and associated to $SPOKE_SUBNET"
