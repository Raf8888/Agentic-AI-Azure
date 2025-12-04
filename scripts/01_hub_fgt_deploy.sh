#!/usr/bin/env bash
set -euo pipefail

AZURE_REGION="${AZURE_REGION:-westeurope}"
RESOURCE_GROUP="rg-fgt-hubspoke"
HUB_VNET="vnet-hub-fgt"
HUB_VNET_PREFIX="10.100.0.0/16"
WAN_SUBNET="snet-fw-wan"
WAN_PREFIX="10.100.0.0/24"
LAN_SUBNET="snet-fw-lan"
LAN_PREFIX="10.100.1.0/24"
FGT_LAN_IP="10.100.1.4"
PUBLIC_IP="pip-fgt-hub"
DNS_LABEL="${DNS_LABEL:-acn-fgt-hub-westeurope}"
WAN_NIC="nic-fgt-wan"
LAN_NIC="nic-fgt-lan"
FGT_VM="vm-fgt-hub"
FGT_ADMIN="fortiadmin"
FGT_ADMIN_PW="Forti@12345Lab!"
VM_SIZE="${VM_SIZE:-Standard_F4s_v2}"
FGT_IMAGE="${FGT_IMAGE:-fortinet:fortinet_fortigate-vm_v5:fortinet_fg-vm:latest}"
PLAN_PUBLISHER="fortinet"
PLAN_PRODUCT="fortinet_fortigate-vm_v5"
PLAN_NAME="fortinet_fg-vm"

log() { echo "[INFO] $*"; }

ensure_nic() {
  local nic_name=$1
  if az network nic show --only-show-errors -g "$RESOURCE_GROUP" -n "$nic_name" >/dev/null 2>&1; then
    log "NIC $nic_name already exists"
    return 0
  fi
  log "Creating NIC $nic_name"
  az network nic create --only-show-errors -g "$RESOURCE_GROUP" -n "$nic_name" "$@" >/dev/null
}

log "Ensuring resource group $RESOURCE_GROUP in $AZURE_REGION"
az group create --only-show-errors -n "$RESOURCE_GROUP" -l "$AZURE_REGION" >/dev/null

log "Ensuring hub VNet $HUB_VNET with subnets"
az network vnet create --only-show-errors \
  -g "$RESOURCE_GROUP" -n "$HUB_VNET" \
  --address-prefixes "$HUB_VNET_PREFIX" \
  --subnet-name "$WAN_SUBNET" --subnet-prefixes "$WAN_PREFIX" >/dev/null
az network vnet subnet create --only-show-errors \
  -g "$RESOURCE_GROUP" --vnet-name "$HUB_VNET" \
  -n "$LAN_SUBNET" --address-prefix "$LAN_PREFIX" >/dev/null

log "Ensuring public IP $PUBLIC_IP with DNS label $DNS_LABEL"
if ! az network public-ip show --only-show-errors -g "$RESOURCE_GROUP" -n "$PUBLIC_IP" >/dev/null 2>&1; then
  az network public-ip create --only-show-errors \
    -g "$RESOURCE_GROUP" -n "$PUBLIC_IP" \
    --sku Standard --allocation-method Static \
    --dns-name "$DNS_LABEL" >/dev/null
else
  log "Public IP $PUBLIC_IP already exists"
fi

log "Ensuring WAN NIC $WAN_NIC"
ensure_nic "$WAN_NIC" --vnet-name "$HUB_VNET" --subnet "$WAN_SUBNET" --public-ip-address "$PUBLIC_IP"
az network nic update --only-show-errors -g "$RESOURCE_GROUP" -n "$WAN_NIC" --set enableIPForwarding=true >/dev/null

log "Ensuring LAN NIC $LAN_NIC"
ensure_nic "$LAN_NIC" --vnet-name "$HUB_VNET" --subnet "$LAN_SUBNET" --private-ip-address "$FGT_LAN_IP"
az network nic update --only-show-errors -g "$RESOURCE_GROUP" -n "$LAN_NIC" --set enableIPForwarding=true >/dev/null

log "Accepting FortiGate marketplace terms (idempotent)"
az vm image terms accept --only-show-errors --publisher "$PLAN_PUBLISHER" --offer "$PLAN_PRODUCT" --plan "$PLAN_NAME" >/dev/null

log "Ensuring FortiGate VM $FGT_VM"
if az vm show --only-show-errors -g "$RESOURCE_GROUP" -n "$FGT_VM" >/dev/null 2>&1; then
  log "VM $FGT_VM already exists"
else
  az vm create --only-show-errors \
    -g "$RESOURCE_GROUP" -n "$FGT_VM" \
    --nics "$WAN_NIC" "$LAN_NIC" \
    --size "$VM_SIZE" \
    --image "$FGT_IMAGE" \
    --admin-username "$FGT_ADMIN" --admin-password "$FGT_ADMIN_PW" \
    --authentication-type password \
    --license-type BYOL \
    --plan publisher="$PLAN_PUBLISHER" product="$PLAN_PRODUCT" name="$PLAN_NAME" >/dev/null
fi

PUB_IP=$(az network public-ip show --only-show-errors -g "$RESOURCE_GROUP" -n "$PUBLIC_IP" --query "ipAddress" -o tsv)
FQDN=$(az network public-ip show --only-show-errors -g "$RESOURCE_GROUP" -n "$PUBLIC_IP" --query "dnsSettings.fqdn" -o tsv)

log "Deployment summary"
echo "Resource Group: $RESOURCE_GROUP"
echo "Hub VNet: $HUB_VNET ($HUB_VNET_PREFIX)"
echo "Subnets: $WAN_SUBNET=$WAN_PREFIX, $LAN_SUBNET=$LAN_PREFIX"
echo "FortiGate VM: $FGT_VM"
echo "Public IP: ${PUB_IP:-N/A}"
echo "FQDN: ${FQDN:-N/A}"
echo "FortiGate LAN IP (port2): $FGT_LAN_IP"
