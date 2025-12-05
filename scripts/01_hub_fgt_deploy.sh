#!/usr/bin/env bash
set -euo pipefail

# Hub FortiGate deployment for Azure hub-spoke lab

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

ensure_rg() {
  log "Ensuring resource group $RESOURCE_GROUP ($AZURE_REGION)"
  az group create --only-show-errors -n "$RESOURCE_GROUP" -l "$AZURE_REGION" >/dev/null
}

ensure_vnet_and_subnets() {
  if az network vnet show --only-show-errors -g "$RESOURCE_GROUP" -n "$HUB_VNET" >/dev/null 2>&1; then
    log "VNet $HUB_VNET already exists"
  else
    log "Creating VNet $HUB_VNET with subnet $WAN_SUBNET"
    az network vnet create --only-show-errors \
      -g "$RESOURCE_GROUP" -n "$HUB_VNET" \
      --address-prefixes "$HUB_VNET_PREFIX" \
      --subnet-name "$WAN_SUBNET" \
      --subnet-prefixes "$WAN_PREFIX" >/dev/null
  fi

  if az network vnet subnet show --only-show-errors -g "$RESOURCE_GROUP" --vnet-name "$HUB_VNET" -n "$LAN_SUBNET" >/dev/null 2>&1; then
    log "Subnet $LAN_SUBNET already exists"
  else
    log "Creating LAN subnet $LAN_SUBNET"
    az network vnet subnet create --only-show-errors \
      -g "$RESOURCE_GROUP" --vnet-name "$HUB_VNET" \
      -n "$LAN_SUBNET" --address-prefixes "$LAN_PREFIX" >/dev/null
  fi
}

ensure_public_ip() {
  if az network public-ip show --only-show-errors -g "$RESOURCE_GROUP" -n "$PUBLIC_IP" >/dev/null 2>&1; then
    log "Public IP $PUBLIC_IP already exists"
  else
    log "Creating public IP $PUBLIC_IP"
    az network public-ip create --only-show-errors \
      -g "$RESOURCE_GROUP" -n "$PUBLIC_IP" \
      --sku Standard \
      --allocation-method Static \
      --dns-name "$DNS_LABEL" >/dev/null
  fi
}

create_or_update_nic() {
  local nic_name=$1
  shift
  if az network nic show --only-show-errors -g "$RESOURCE_GROUP" -n "$nic_name" >/dev/null 2>&1; then
    log "NIC $nic_name already exists, ensuring IP forwarding"
  else
    log "Creating NIC $nic_name"
    az network nic create --only-show-errors \
      -g "$RESOURCE_GROUP" -n "$nic_name" \
      "$@" >/dev/null
  fi
  az network nic update --only-show-errors -g "$RESOURCE_GROUP" -n "$nic_name" --set enableIPForwarding=true >/dev/null
}

ensure_marketplace_terms() {
  log "Accepting Fortinet BYOL marketplace terms (idempotent)"
  az vm image terms accept --only-show-errors --publisher "$PLAN_PUBLISHER" --offer "$PLAN_PRODUCT" --plan "$PLAN_NAME" >/dev/null
}

ensure_vm() {
  if az vm show --only-show-errors -g "$RESOURCE_GROUP" -n "$FGT_VM" >/dev/null 2>&1; then
    log "FortiGate VM $FGT_VM already exists"
    return
  fi

  ensure_marketplace_terms
  log "Creating FortiGate VM $FGT_VM"
  az vm create --only-show-errors \
    -g "$RESOURCE_GROUP" -n "$FGT_VM" \
    --nics "$WAN_NIC" "$LAN_NIC" \
    --size "$VM_SIZE" \
    --image "$FGT_IMAGE" \
    --admin-username "$FGT_ADMIN" \
    --admin-password "$FGT_ADMIN_PW" \
    --authentication-type password \
    --license-type BYOL \
    --plan publisher="$PLAN_PUBLISHER" product="$PLAN_PRODUCT" name="$PLAN_NAME" >/dev/null
}

print_summary() {
  pub_ip=$(az network public-ip show --only-show-errors -g "$RESOURCE_GROUP" -n "$PUBLIC_IP" --query ipAddress -o tsv 2>/dev/null || true)
  fqdn=$(az network public-ip show --only-show-errors -g "$RESOURCE_GROUP" -n "$PUBLIC_IP" --query dnsSettings.fqdn -o tsv 2>/dev/null || true)

  echo "==== Hub Deployment Summary ===="
  echo "Resource Group : $RESOURCE_GROUP"
  echo "Region         : $AZURE_REGION"
  echo "Hub VNet       : $HUB_VNET ($HUB_VNET_PREFIX)"
  echo "Subnets        : $WAN_SUBNET=$WAN_PREFIX, $LAN_SUBNET=$LAN_PREFIX"
  echo "NICs           : $WAN_NIC, $LAN_NIC"
  echo "FortiGate VM   : $FGT_VM"
  echo "Public IP      : ${pub_ip:-pending}"
  echo "FQDN           : ${fqdn:-pending}"
  echo "FGT LAN IP     : $FGT_LAN_IP"
}

ensure_rg
ensure_vnet_and_subnets
ensure_public_ip
create_or_update_nic "$WAN_NIC" --vnet-name "$HUB_VNET" --subnet "$WAN_SUBNET" --public-ip-address "$PUBLIC_IP"
create_or_update_nic "$LAN_NIC" --vnet-name "$HUB_VNET" --subnet "$LAN_SUBNET" --private-ip-address "$FGT_LAN_IP"
ensure_vm
print_summary
