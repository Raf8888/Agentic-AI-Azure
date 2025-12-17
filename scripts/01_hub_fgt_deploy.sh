#!/usr/bin/env bash
set -euo pipefail

# Hub + FortiGate (idempotent, safe rerun)

LOCATION="${LOCATION:-westeurope}"
RG="${RG:-rg-fgt-hubspoke}"

HUB_VNET="${HUB_VNET:-vnet-hub-fgt}"
HUB_VNET_CIDR="${HUB_VNET_CIDR:-10.100.0.0/16}"

WAN_SUBNET_DESIRED="${WAN_SUBNET_DESIRED:-snet-fgt-wan}"
WAN_SUBNET_CIDR="${WAN_SUBNET_CIDR:-10.100.0.0/24}"
LAN_SUBNET_DESIRED="${LAN_SUBNET_DESIRED:-snet-fgt-lan}"
LAN_SUBNET_CIDR="${LAN_SUBNET_CIDR:-10.100.1.0/24}"

PIP_NAME="${PIP_NAME:-pip-fgt-hub}"
FGT_DNS_LABEL="${FGT_DNS_LABEL:-}"

FGT_VM="${FGT_VM:-vm-fgt-hub}"
WAN_NIC="${WAN_NIC:-nic-fgt-wan}"
LAN_NIC="${LAN_NIC:-nic-fgt-lan}"
FGT_LAN_IP="${FGT_LAN_IP:-10.100.1.4}"

WAN_NSG="${WAN_NSG:-nsg-fgt-wan}"
LAN_NSG="${LAN_NSG:-nsg-fgt-lan}"

MY_IP_CIDR="${MY_IP_CIDR:-0.0.0.0/0}"

FGT_VM_ADMIN_USER="${FGT_VM_ADMIN_USER:-admin}"
FGT_VM_ADMIN_PASS="${FGT_VM_ADMIN_PASS:-FortiGate@12345}"

FGT_IMAGE_URN="${FGT_IMAGE_URN:-fortinet:fortinet_fortigate-vm_v5:fortinet_fg-vm_payg_2023:latest}"
PLAN_PUBLISHER="${PLAN_PUBLISHER:-fortinet}"
PLAN_PRODUCT="${PLAN_PRODUCT:-fortinet_fortigate-vm_v5}"
PLAN_NAME="${PLAN_NAME:-fortinet_fg-vm_payg_2023}"

BOOTSTRAP_CONFIG_FILE="$(mktemp)"

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

require_cli() {
  az account show --output none >/dev/null
}

ensure_rg() {
  log "Ensuring resource group $RG"
  az_with_retry az group create -n "$RG" -l "$LOCATION" --only-show-errors >/dev/null
}

ensure_hub_vnet_and_subnets() {
  log "Ensuring hub VNet $HUB_VNET"
  if ! az network vnet show -g "$RG" -n "$HUB_VNET" --only-show-errors >/dev/null 2>&1; then
    az_with_retry az network vnet create \
      -g "$RG" -n "$HUB_VNET" -l "$LOCATION" \
      --address-prefixes "$HUB_VNET_CIDR" \
      --subnet-name "$WAN_SUBNET_DESIRED" --subnet-prefixes "$WAN_SUBNET_CIDR" \
      --only-show-errors >/dev/null
  fi
  if ! az network vnet subnet show -g "$RG" --vnet-name "$HUB_VNET" -n "$LAN_SUBNET_DESIRED" --only-show-errors >/dev/null 2>&1; then
    az_with_retry az network vnet subnet create \
      -g "$RG" --vnet-name "$HUB_VNET" -n "$LAN_SUBNET_DESIRED" \
      --address-prefixes "$LAN_SUBNET_CIDR" --only-show-errors >/dev/null
  fi
}

ensure_pip_and_dns() {
  log "Ensuring public IP $PIP_NAME"
  if ! az network public-ip show -g "$RG" -n "$PIP_NAME" --only-show-errors >/dev/null 2>&1; then
    az_with_retry az network public-ip create \
      -g "$RG" -n "$PIP_NAME" -l "$LOCATION" \
      --sku Standard --allocation-method Static --version IPv4 \
      --only-show-errors >/dev/null
  fi

  local current_label
  current_label=$(az network public-ip show -g "$RG" -n "$PIP_NAME" --query "dnsSettings.domainNameLabel" -o tsv 2>/dev/null || true)
  if [[ -z "$FGT_DNS_LABEL" ]]; then
    if [[ -n "$current_label" ]]; then
      FGT_DNS_LABEL="$current_label"
    else
      local run_id="${GITHUB_RUN_ID:-local}"
      FGT_DNS_LABEL="fgt-${run_id}-${LOCATION}"
      FGT_DNS_LABEL="${FGT_DNS_LABEL,,}"
      FGT_DNS_LABEL="${FGT_DNS_LABEL//_/}"
      FGT_DNS_LABEL="${FGT_DNS_LABEL//./-}"
      FGT_DNS_LABEL="${FGT_DNS_LABEL:0:63}"
    fi
  fi

  if [[ -z "$current_label" ]]; then
    log "Setting public DNS label on $PIP_NAME: $FGT_DNS_LABEL"
    az_with_retry az network public-ip update -g "$RG" -n "$PIP_NAME" --dns-name "$FGT_DNS_LABEL" --only-show-errors >/dev/null
  fi
}

discover_or_default_subnets() {
  WAN_SUBNET="$WAN_SUBNET_DESIRED"
  LAN_SUBNET="$LAN_SUBNET_DESIRED"

  if az network nic show -g "$RG" -n "$WAN_NIC" --only-show-errors >/dev/null 2>&1; then
    WAN_SUBNET=$(az network nic show -g "$RG" -n "$WAN_NIC" --query "ipConfigurations[0].subnet.id" -o tsv | awk -F/ '{print $NF}')
  fi
  if az network nic show -g "$RG" -n "$LAN_NIC" --only-show-errors >/dev/null 2>&1; then
    LAN_SUBNET=$(az network nic show -g "$RG" -n "$LAN_NIC" --query "ipConfigurations[0].subnet.id" -o tsv | awk -F/ '{print $NF}')
  fi

  if ! az network vnet subnet show -g "$RG" --vnet-name "$HUB_VNET" -n "$WAN_SUBNET" --only-show-errors >/dev/null 2>&1; then
    log "Creating WAN subnet $WAN_SUBNET"
    az_with_retry az network vnet subnet create -g "$RG" --vnet-name "$HUB_VNET" -n "$WAN_SUBNET" --address-prefixes "$WAN_SUBNET_CIDR" --only-show-errors >/dev/null
  fi
  if ! az network vnet subnet show -g "$RG" --vnet-name "$HUB_VNET" -n "$LAN_SUBNET" --only-show-errors >/dev/null 2>&1; then
    log "Creating LAN subnet $LAN_SUBNET"
    az_with_retry az network vnet subnet create -g "$RG" --vnet-name "$HUB_VNET" -n "$LAN_SUBNET" --address-prefixes "$LAN_SUBNET_CIDR" --only-show-errors >/dev/null
  fi
}

ensure_nsg_rule() {
  local nsg=$1 name=$2 priority=$3 direction=$4 access=$5 protocol=$6 src=$7 dst_ports=$8
  local proto_arg
  if [[ "$protocol" == "*" ]]; then
    proto_arg="\\*"
  else
    proto_arg="$protocol"
  fi

  if az network nsg rule show -g "$RG" --nsg-name "$nsg" -n "$name" --only-show-errors >/dev/null 2>&1; then
    if [[ "$protocol" == "*" ]]; then
      az_with_retry az network nsg rule update -g "$RG" --nsg-name "$nsg" -n "$name" \
        --priority "$priority" --direction "$direction" --access "$access" --protocol \* \
        --source-address-prefixes "$src" --source-port-ranges "*" \
        --destination-address-prefixes "*" --destination-port-ranges "$dst_ports" \
        --only-show-errors >/dev/null
    else
      az_with_retry az network nsg rule update -g "$RG" --nsg-name "$nsg" -n "$name" \
        --priority "$priority" --direction "$direction" --access "$access" --protocol "$proto_arg" \
        --source-address-prefixes "$src" --source-port-ranges "*" \
        --destination-address-prefixes "*" --destination-port-ranges "$dst_ports" \
        --only-show-errors >/dev/null
    fi
  else
    if [[ "$protocol" == "*" ]]; then
      az_with_retry az network nsg rule create -g "$RG" --nsg-name "$nsg" -n "$name" \
        --priority "$priority" --direction "$direction" --access "$access" --protocol \* \
        --source-address-prefixes "$src" --source-port-ranges "*" \
        --destination-address-prefixes "*" --destination-port-ranges "$dst_ports" \
        --only-show-errors >/dev/null
    else
      az_with_retry az network nsg rule create -g "$RG" --nsg-name "$nsg" -n "$name" \
        --priority "$priority" --direction "$direction" --access "$access" --protocol "$proto_arg" \
        --source-address-prefixes "$src" --source-port-ranges "*" \
        --destination-address-prefixes "*" --destination-port-ranges "$dst_ports" \
        --only-show-errors >/dev/null
    fi
  fi
}

ensure_nsgs_and_associations() {
  log "Ensuring WAN NSG $WAN_NSG and associating to subnet $WAN_SUBNET"
  az_with_retry az network nsg create -g "$RG" -n "$WAN_NSG" -l "$LOCATION" --only-show-errors >/dev/null
  ensure_nsg_rule "$WAN_NSG" "Allow-HTTPS-In" 100 Inbound Allow Tcp "$MY_IP_CIDR" 443
  ensure_nsg_rule "$WAN_NSG" "Allow-SSH-In" 110 Inbound Allow Tcp "$MY_IP_CIDR" 22
  ensure_nsg_rule "$WAN_NSG" "Allow-ICMP-In" 120 Inbound Allow Icmp "$MY_IP_CIDR" "*"
  az_with_retry az network vnet subnet update -g "$RG" --vnet-name "$HUB_VNET" -n "$WAN_SUBNET" --network-security-group "$WAN_NSG" --only-show-errors >/dev/null

  log "Ensuring LAN NSG $LAN_NSG and associating to subnet $LAN_SUBNET"
  az_with_retry az network nsg create -g "$RG" -n "$LAN_NSG" -l "$LOCATION" --only-show-errors >/dev/null
  ensure_nsg_rule "$LAN_NSG" "Allow-VNet-In" 100 Inbound Allow "*" "VirtualNetwork" "*"
  ensure_nsg_rule "$LAN_NSG" "Allow-FGT-LAN-In" 110 Inbound Allow "*" "$FGT_LAN_IP" "*"
  ensure_nsg_rule "$LAN_NSG" "Deny-Internet-In" 400 Inbound Deny "*" "Internet" "*"
  az_with_retry az network vnet subnet update -g "$RG" --vnet-name "$HUB_VNET" -n "$LAN_SUBNET" --network-security-group "$LAN_NSG" --only-show-errors >/dev/null
}

ensure_nics() {
  log "Ensuring WAN NIC $WAN_NIC"
  if ! az network nic show -g "$RG" -n "$WAN_NIC" --only-show-errors >/dev/null 2>&1; then
    az_with_retry az network nic create \
      -g "$RG" -n "$WAN_NIC" -l "$LOCATION" \
      --vnet-name "$HUB_VNET" --subnet "$WAN_SUBNET" \
      --public-ip-address "$PIP_NAME" \
      --ip-forwarding true \
      --only-show-errors >/dev/null
  fi
  az_with_retry az network nic update -g "$RG" -n "$WAN_NIC" --ip-forwarding true --only-show-errors >/dev/null
  wan_ipcfg=$(az network nic show -g "$RG" -n "$WAN_NIC" --query "ipConfigurations[0].name" -o tsv)
  az_with_retry az network nic ip-config update -g "$RG" --nic-name "$WAN_NIC" -n "$wan_ipcfg" --public-ip-address "$PIP_NAME" --only-show-errors >/dev/null

  log "Ensuring LAN NIC $LAN_NIC"
  if ! az network nic show -g "$RG" -n "$LAN_NIC" --only-show-errors >/dev/null 2>&1; then
    az_with_retry az network nic create \
      -g "$RG" -n "$LAN_NIC" -l "$LOCATION" \
      --vnet-name "$HUB_VNET" --subnet "$LAN_SUBNET" \
      --private-ip-address "$FGT_LAN_IP" \
      --ip-forwarding true \
      --only-show-errors >/dev/null
  fi
  az_with_retry az network nic update -g "$RG" -n "$LAN_NIC" --ip-forwarding true --only-show-errors >/dev/null
  lan_ipcfg=$(az network nic show -g "$RG" -n "$LAN_NIC" --query "ipConfigurations[0].name" -o tsv)
  az_with_retry az network nic ip-config update -g "$RG" --nic-name "$LAN_NIC" -n "$lan_ipcfg" --private-ip-address "$FGT_LAN_IP" --only-show-errors >/dev/null
}

write_bootstrap_custom_data() {
  # FortiGate reads customData as bootstrap; keep content deterministic
  cat >"$BOOTSTRAP_CONFIG_FILE" <<EOF
config system admin
    edit "admin"
        set password ${FGT_VM_ADMIN_PASS}
    next
end

config system interface
    edit "port1"
        set mode dhcp
        set allowaccess ping https ssh
    next
    edit "port2"
        set mode static
        set ip ${FGT_LAN_IP} 255.255.255.0
        set allowaccess ping https ssh
    next
end

config router static
    edit 1
        set dst 0.0.0.0 0.0.0.0
        set gateway 10.100.0.1
        set device "port1"
    next
end

config firewall policy
    edit 1
        set name "WAN-to-LAN"
        set srcintf "port1"
        set dstintf "port2"
        set srcaddr "all"
        set dstaddr "all"
        set action accept
        set schedule "always"
        set service "HTTPS" "PING"
    next
    edit 2
        set name "LAN-to-WAN"
        set srcintf "port2"
        set dstintf "port1"
        set srcaddr "all"
        set dstaddr "all"
        set action accept
        set schedule "always"
        set service "ALL"
        set nat enable
    next
end
EOF
}

ensure_fgt_vm() {
  log "Ensuring Fortinet marketplace terms accepted"
  az_with_retry az vm image terms accept --urn "$FGT_IMAGE_URN" --only-show-errors >/dev/null

  log "Ensuring FortiGate VM $FGT_VM"
  if ! az vm show -g "$RG" -n "$FGT_VM" --only-show-errors >/dev/null 2>&1; then
    write_bootstrap_custom_data
    az_with_retry az vm create \
      -g "$RG" -n "$FGT_VM" -l "$LOCATION" \
      --nics "$WAN_NIC" "$LAN_NIC" \
      --image "$FGT_IMAGE_URN" \
      --size Standard_F4s_v2 \
      --admin-username "$FGT_VM_ADMIN_USER" \
      --admin-password "$FGT_VM_ADMIN_PASS" \
      --plan-publisher "$PLAN_PUBLISHER" \
      --plan-product "$PLAN_PRODUCT" \
      --plan-name "$PLAN_NAME" \
      --custom-data "$BOOTSTRAP_CONFIG_FILE" \
      --os-disk-size-gb 60 \
      --storage-sku StandardSSD_LRS \
      --only-show-errors >/dev/null
  fi
}

final_output() {
  local ip fqdn
  ip=$(az network public-ip show -g "$RG" -n "$PIP_NAME" --query "ipAddress" -o tsv 2>/dev/null || true)
  fqdn=$(az network public-ip show -g "$RG" -n "$PIP_NAME" --query "dnsSettings.fqdn" -o tsv 2>/dev/null || true)
  echo
  echo "FortiGate Public IP: ${ip:-}"
  echo "FortiGate FQDN:      ${fqdn:-}"
  if [[ -n "$fqdn" ]]; then
    echo "GUI URL:             https://${fqdn}"
  fi
  echo "Admin Username:      ${FGT_VM_ADMIN_USER}"
}

self_heal_validate_best_effort() {
  # Never fail the workflow from this section
  log "Self-heal validate (best-effort, never fails job)"

  if ! az network vnet subnet show -g "$RG" --vnet-name "$HUB_VNET" -n "$WAN_SUBNET" --query "networkSecurityGroup.id" -o tsv 2>/dev/null | grep -q "/networkSecurityGroups/$WAN_NSG"; then
    warn "WAN subnet NSG association missing; re-applying"
    az_with_retry az network vnet subnet update -g "$RG" --vnet-name "$HUB_VNET" -n "$WAN_SUBNET" --network-security-group "$WAN_NSG" --only-show-errors >/dev/null || true
  fi
  if ! az network vnet subnet show -g "$RG" --vnet-name "$HUB_VNET" -n "$LAN_SUBNET" --query "networkSecurityGroup.id" -o tsv 2>/dev/null | grep -q "/networkSecurityGroups/$LAN_NSG"; then
    warn "LAN subnet NSG association missing; re-applying"
    az_with_retry az network vnet subnet update -g "$RG" --vnet-name "$HUB_VNET" -n "$LAN_SUBNET" --network-security-group "$LAN_NSG" --only-show-errors >/dev/null || true
  fi
  if ! az vm show -g "$RG" -n "$FGT_VM" --query "provisioningState" -o tsv 2>/dev/null | grep -q "Succeeded"; then
    warn "FortiGate VM not in Succeeded provisioningState"
  fi
  local fqdn
  fqdn=$(az network public-ip show -g "$RG" -n "$PIP_NAME" --query "dnsSettings.fqdn" -o tsv 2>/dev/null || true)
  if [[ -n "$fqdn" ]]; then
    if ! curl -k -m 5 -s "https://${fqdn}" >/dev/null 2>&1; then
      warn "FortiGate HTTPS not reachable yet (best-effort check)"
    fi
  fi
  return 0
}

cleanup() {
  rm -f "$BOOTSTRAP_CONFIG_FILE" || true
}
trap cleanup EXIT

require_cli
log "Vars: LOCATION=$LOCATION RG=$RG VNET=$HUB_VNET IMAGE_URN=$FGT_IMAGE_URN PLAN=$PLAN_PUBLISHER/$PLAN_PRODUCT/$PLAN_NAME"

ensure_rg
ensure_hub_vnet_and_subnets
ensure_pip_and_dns
discover_or_default_subnets
ensure_nsgs_and_associations
ensure_nics
ensure_fgt_vm
self_heal_validate_best_effort || true
final_output
