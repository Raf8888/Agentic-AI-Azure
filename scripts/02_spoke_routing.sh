#!/usr/bin/env bash
set -euo pipefail

# Spoke + routing via FortiGate (idempotent, safe rerun)

LOCATION="${LOCATION:-westeurope}"
RG="${RG:-rg-fgt-hubspoke}"

HUB_VNET="${HUB_VNET:-vnet-hub-fgt}"
FGT_LAN_NIC="${FGT_LAN_NIC:-nic-fgt-lan}"

SPOKE_VNET="${SPOKE_VNET:-vnet-spoke-app}"
SPOKE_VNET_CIDR="${SPOKE_VNET_CIDR:-10.101.0.0/16}"
SPOKE_SUBNET="${SPOKE_SUBNET:-snet-app}"
SPOKE_SUBNET_CIDR="${SPOKE_SUBNET_CIDR:-10.101.1.0/24}"

SPOKE_NSG="${SPOKE_NSG:-nsg-spoke-app}"
MY_IP_CIDR="${MY_IP_CIDR:-0.0.0.0/0}"

SPOKE_NIC="${SPOKE_NIC:-nic-spoke-app}"
SPOKE_VM="${SPOKE_VM:-vm-spoke-app}"
SPOKE_VM_ADMIN_USER="${SPOKE_VM_ADMIN_USER:-labadmin}"
SPOKE_VM_ADMIN_PASS="${SPOKE_VM_ADMIN_PASS:-LabNet!2025xY}"

PEER_HUB_TO_SPOKE="${PEER_HUB_TO_SPOKE:-hub-to-spoke}"
PEER_SPOKE_TO_HUB="${PEER_SPOKE_TO_HUB:-spoke-to-hub}"

RT_NAME="${RT_NAME:-rt-spoke-to-fgt}"
RT_ROUTE_NAME="${RT_ROUTE_NAME:-default-via-fgt}"

log() { echo "[INFO] $*"; }
warn() { echo "[WARN] $*"; }

az_with_retry() {
  local attempt=1 max=3 delay=5
  while true; do
    if "$@"; then return 0; fi
    if (( attempt >= max )); then
      echo "[ERROR] Command failed after $max attempts: $*" >&2
      return 1
    fi
    warn "Retrying (attempt $attempt/$max) in ${delay}s: $*"
    sleep "$delay"
    attempt=$((attempt+1))
    delay=$((delay*2))
  done
}

require_cli() { az account show --output none >/dev/null; }

discover_fgt_lan_ip() {
  local ip
  ip=$(az network nic show -g "$RG" -n "$FGT_LAN_NIC" --query "ipConfigurations[0].privateIpAddress" -o tsv 2>/dev/null || true)
  if [[ -z "$ip" ]]; then
    echo "[ERROR] Unable to discover FortiGate LAN IP from NIC $FGT_LAN_NIC" >&2
    exit 1
  fi
  FGT_LAN_IP="$ip"
  log "FortiGate LAN IP: $FGT_LAN_IP"
}

ensure_spoke_vnet() {
  log "Ensuring spoke VNet $SPOKE_VNET"
  if ! az network vnet show -g "$RG" -n "$SPOKE_VNET" --only-show-errors >/dev/null 2>&1; then
    az_with_retry az network vnet create \
      -g "$RG" -n "$SPOKE_VNET" -l "$LOCATION" \
      --address-prefixes "$SPOKE_VNET_CIDR" \
      --subnet-name "$SPOKE_SUBNET" --subnet-prefixes "$SPOKE_SUBNET_CIDR" \
      --only-show-errors >/dev/null
  fi
  # Backward-compat: if desired subnet is missing but snet-spoke-app exists, use it
  if ! az network vnet subnet show -g "$RG" --vnet-name "$SPOKE_VNET" -n "$SPOKE_SUBNET" --only-show-errors >/dev/null 2>&1; then
    if az network vnet subnet show -g "$RG" --vnet-name "$SPOKE_VNET" -n "snet-spoke-app" --only-show-errors >/dev/null 2>&1; then
      SPOKE_SUBNET="snet-spoke-app"
      log "Using existing spoke subnet $SPOKE_SUBNET"
    else
      az_with_retry az network vnet subnet create -g "$RG" --vnet-name "$SPOKE_VNET" -n "$SPOKE_SUBNET" --address-prefixes "$SPOKE_SUBNET_CIDR" --only-show-errors >/dev/null
    fi
  fi
}

ensure_spoke_nsg() {
  log "Ensuring spoke NSG $SPOKE_NSG"
  az_with_retry az network nsg create -g "$RG" -n "$SPOKE_NSG" -l "$LOCATION" --only-show-errors >/dev/null
  if az network nsg rule show -g "$RG" --nsg-name "$SPOKE_NSG" -n "Allow-SSH-In" --only-show-errors >/dev/null 2>&1; then
    az_with_retry az network nsg rule update -g "$RG" --nsg-name "$SPOKE_NSG" -n "Allow-SSH-In" \
      --priority 100 --direction Inbound --access Allow --protocol Tcp \
      --source-address-prefixes "$MY_IP_CIDR" --source-port-ranges "*" \
      --destination-address-prefixes "*" --destination-port-ranges 22 \
      --only-show-errors >/dev/null
  else
    az_with_retry az network nsg rule create -g "$RG" --nsg-name "$SPOKE_NSG" -n "Allow-SSH-In" \
      --priority 100 --direction Inbound --access Allow --protocol Tcp \
      --source-address-prefixes "$MY_IP_CIDR" --source-port-ranges "*" \
      --destination-address-prefixes "*" --destination-port-ranges 22 \
      --only-show-errors >/dev/null
  fi
}

ensure_spoke_nic_and_vm() {
  log "Ensuring spoke NIC $SPOKE_NIC"
  if ! az network nic show -g "$RG" -n "$SPOKE_NIC" --only-show-errors >/dev/null 2>&1; then
    az_with_retry az network nic create \
      -g "$RG" -n "$SPOKE_NIC" -l "$LOCATION" \
      --vnet-name "$SPOKE_VNET" --subnet "$SPOKE_SUBNET" \
      --network-security-group "$SPOKE_NSG" \
      --only-show-errors >/dev/null
  fi

  log "Ensuring spoke VM $SPOKE_VM (no public IP)"
  if ! az vm show -g "$RG" -n "$SPOKE_VM" --only-show-errors >/dev/null 2>&1; then
    az_with_retry az vm create \
      -g "$RG" -n "$SPOKE_VM" -l "$LOCATION" \
      --image Ubuntu2204 \
      --size Standard_B1s \
      --admin-username "$SPOKE_VM_ADMIN_USER" \
      --admin-password "$SPOKE_VM_ADMIN_PASS" \
      --authentication-type password \
      --nics "$SPOKE_NIC" \
      --public-ip-address "" \
      --only-show-errors >/dev/null
  fi
}

ensure_peering() {
  log "Ensuring hub<->spoke peering with forwarded traffic"
  hub_id=$(az network vnet show -g "$RG" -n "$HUB_VNET" --query id -o tsv)
  spoke_id=$(az network vnet show -g "$RG" -n "$SPOKE_VNET" --query id -o tsv)

  if ! az network vnet peering show -g "$RG" --vnet-name "$HUB_VNET" -n "$PEER_HUB_TO_SPOKE" --only-show-errors >/dev/null 2>&1; then
    az_with_retry az network vnet peering create -g "$RG" --vnet-name "$HUB_VNET" -n "$PEER_HUB_TO_SPOKE" \
      --remote-vnet "$spoke_id" --allow-vnet-access --allow-forwarded-traffic --only-show-errors >/dev/null
  fi
  if ! az network vnet peering show -g "$RG" --vnet-name "$SPOKE_VNET" -n "$PEER_SPOKE_TO_HUB" --only-show-errors >/dev/null 2>&1; then
    az_with_retry az network vnet peering create -g "$RG" --vnet-name "$SPOKE_VNET" -n "$PEER_SPOKE_TO_HUB" \
      --remote-vnet "$hub_id" --allow-vnet-access --allow-forwarded-traffic --only-show-errors >/dev/null
  fi
}

ensure_udr() {
  log "Ensuring route table $RT_NAME and default route via FortiGate $FGT_LAN_IP"
  if ! az network route-table show -g "$RG" -n "$RT_NAME" --only-show-errors >/dev/null 2>&1; then
    az_with_retry az network route-table create -g "$RG" -n "$RT_NAME" -l "$LOCATION" --only-show-errors >/dev/null
  fi
  if az network route-table route show -g "$RG" --route-table-name "$RT_NAME" -n "$RT_ROUTE_NAME" --only-show-errors >/dev/null 2>&1; then
    az_with_retry az network route-table route update -g "$RG" --route-table-name "$RT_NAME" -n "$RT_ROUTE_NAME" \
      --address-prefix 0.0.0.0/0 --next-hop-type VirtualAppliance --next-hop-ip-address "$FGT_LAN_IP" --only-show-errors >/dev/null
  else
    az_with_retry az network route-table route create -g "$RG" --route-table-name "$RT_NAME" -n "$RT_ROUTE_NAME" \
      --address-prefix 0.0.0.0/0 --next-hop-type VirtualAppliance --next-hop-ip-address "$FGT_LAN_IP" --only-show-errors >/dev/null
  fi
  az network vnet subnet list -g "$RG" --vnet-name "$SPOKE_VNET" --query "[].name" -o tsv | while read -r subnet_name; do
    [[ -z "$subnet_name" ]] && continue
    az_with_retry az network vnet subnet update -g "$RG" --vnet-name "$SPOKE_VNET" -n "$subnet_name" --route-table "$RT_NAME" --only-show-errors >/dev/null
  done
}

final_output() {
  spoke_ip=$(az vm list-ip-addresses -g "$RG" -n "$SPOKE_VM" --query "[0].virtualMachine.network.privateIpAddresses[0]" -o tsv 2>/dev/null || true)
  echo
  echo "Spoke VNet:   $SPOKE_VNET ($SPOKE_VNET_CIDR)"
  echo "Spoke Subnet: $SPOKE_SUBNET ($SPOKE_SUBNET_CIDR)"
  echo "Spoke VM:     $SPOKE_VM"
  echo "Spoke VM IP:  ${spoke_ip:-}"
  echo "UDR:          $RT_NAME -> $FGT_LAN_IP"
}

require_cli
discover_fgt_lan_ip
ensure_spoke_vnet
ensure_spoke_nsg
ensure_spoke_nic_and_vm
ensure_peering
ensure_udr
final_output
