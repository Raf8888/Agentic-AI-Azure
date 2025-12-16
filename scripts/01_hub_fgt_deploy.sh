#!/usr/bin/env bash
set -euo pipefail

# Hub + FortiGate deployment with DNS, NSG, routing, bootstrap, and self-heal

RG_NAME="rg-fgt-hubspoke"
LOCATION="westeurope"

HUB_VNET_NAME="vnet-hub-fgt"
HUB_VNET_CIDR="10.100.0.0/16"
SUBNET_FW_WAN="snet-fw-wan"
SUBNET_FW_WAN_CIDR="10.100.0.0/24"
SUBNET_FW_LAN="snet-fw-lan"
SUBNET_FW_LAN_CIDR="10.100.1.0/24"

WAN_NIC_NAME="nic-fgt-wan"
LAN_NIC_NAME="nic-fgt-lan"
WAN_NSG_NAME="nsg-fgt-wan"
LAN_NSG_NAME="nsg-fgt-lan"

PIP_NAME="pip-fgt-hub"
FGT_VM_NAME="vm-fgt-hub"
FGT_DNS_LABEL="${FGT_DNS_LABEL:-fgt-hub-lab}"

FGT_LAN_IP="10.100.1.4"

FGT_ADMIN_USER="admin"
FGT_ADMIN_PASSWORD="FortiGate@12345"

# FortiGate PAYG image
FGT_IMAGE="fortinet:fortinet_fortigate-vm_v5:fortinet_fg-vm_payg_2023:latest"
PLAN_PUBLISHER="fortinet"
PLAN_PRODUCT="fortinet_fortigate-vm_v5"
PLAN_NAME="fortinet_fg-vm_payg_2023"

SPOKE_VNET_NAME="vnet-spoke-app"
ROUTE_TABLE_DEFAULT="rt-spoke-default"
ROUTE_NAME_DEFAULT="default-via-fgt"

PRIVATE_DNS_ZONE="internal.lab"
RECORD_FGT="fgt-hub.internal.lab"
RECORD_SPOKE_VM="spoke-vm.internal.lab"

ALLOW_SSH_IP="${ALLOW_SSH_IP:-0.0.0.0/0}"

BOOTSTRAP_CONFIG=$(cat <<'CFG'
config system global
    set admintimeout 30
end

config system interface
    edit "port1"
        set mode dhcp
        set allowaccess ping https ssh http
    next
    edit "port2"
        set mode static
        set ip 10.100.1.4 255.255.255.0
        set allowaccess ping https ssh
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
        set logtraffic all
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
CFG
)

az_with_retry() {
  local attempt=1 max=3 delay=5
  while true; do
    if "$@"; then
      return 0
    fi
    if (( attempt >= max )); then
      echo "[ERROR] Command failed after $max attempts: $*" >&2
      return 1
    fi
    echo "[WARN] Command failed (attempt $attempt/$max), retrying in ${delay}s: $*"
    sleep "$delay"
    attempt=$((attempt+1))
    delay=$((delay*2))
  done
}

require_var() {
  local name=$1 value=${!1:-}
  if [[ -z "$value" ]]; then
    echo "[ERROR] Required variable $name is empty" >&2
    exit 1
  fi
}

preflight_checks() {
  echo "[00] Preflight checks"
  az account show --output none
  for v in RG_NAME LOCATION HUB_VNET_NAME HUB_VNET_CIDR SUBNET_FW_WAN SUBNET_FW_WAN_CIDR SUBNET_FW_LAN SUBNET_FW_LAN_CIDR \
    WAN_NIC_NAME LAN_NIC_NAME WAN_NSG_NAME LAN_NSG_NAME ROUTE_TABLE_DEFAULT ROUTE_NAME_DEFAULT \
    PIP_NAME FGT_VM_NAME FGT_LAN_IP FGT_ADMIN_USER FGT_ADMIN_PASSWORD FGT_IMAGE PLAN_PUBLISHER PLAN_PRODUCT PLAN_NAME \
    PRIVATE_DNS_ZONE RECORD_FGT RECORD_SPOKE_VM; do
    require_var "$v"
  done
  echo "[INFO] Using image URN: $FGT_IMAGE"
  echo "[INFO] Plan: publisher=$PLAN_PUBLISHER product=$PLAN_PRODUCT name=$PLAN_NAME"
}

accept_fortinet_terms() {
  echo "[00b] Accepting Fortinet marketplace terms (idempotent)"
  az_with_retry az vm image terms accept --only-show-errors --publisher "$PLAN_PUBLISHER" --offer "$PLAN_PRODUCT" --plan "$PLAN_NAME" >/dev/null
}

ensure_dns_public_label() {
  echo "[DNS] Ensuring public IP has DNS label $FGT_DNS_LABEL"
  current=$(az network public-ip show -g "$RG_NAME" -n "$PIP_NAME" --query "dnsSettings.domainNameLabel" -o tsv 2>/dev/null || true)
  if [[ -z "$current" ]]; then
    az_with_retry az network public-ip update -g "$RG_NAME" -n "$PIP_NAME" --dns-name "$FGT_DNS_LABEL" --only-show-errors >/dev/null
  fi
}

ensure_private_dns() {
  echo "[DNS] Ensuring private DNS zone $PRIVATE_DNS_ZONE"
  az_with_retry az network private-dns zone create -g "$RG_NAME" -n "$PRIVATE_DNS_ZONE" >/dev/null
  for vnet in "$HUB_VNET_NAME" "$SPOKE_VNET_NAME"; do
    if az network vnet show -g "$RG_NAME" -n "$vnet" >/dev/null 2>&1; then
      link_name="${vnet}-link"
      if ! az network private-dns link vnet show -g "$RG_NAME" -z "$PRIVATE_DNS_ZONE" -n "$link_name" >/dev/null 2>&1; then
        az_with_retry az network private-dns link vnet create -g "$RG_NAME" -z "$PRIVATE_DNS_ZONE" -n "$link_name" --virtual-network "$(az network vnet show -g "$RG_NAME" -n "$vnet" --query id -o tsv)" --registration-enabled false >/dev/null
      fi
    fi
  done
  if [[ -n "${SPOKE_VM_IP:-}" ]]; then
    az_with_retry az network private-dns record-set a add-record -g "$RG_NAME" -z "$PRIVATE_DNS_ZONE" -n "${RECORD_SPOKE_VM%%.*}" -a "$SPOKE_VM_IP" >/dev/null
  fi
  az_with_retry az network private-dns record-set a add-record -g "$RG_NAME" -z "$PRIVATE_DNS_ZONE" -n "${RECORD_FGT%%.*}" -a "$FGT_LAN_IP" >/dev/null
}

ensure_wan_nsg() {
  echo "[NSG-WAN] Ensuring NSG $WAN_NSG_NAME"
  az_with_retry az network nsg create -g "$RG_NAME" -n "$WAN_NSG_NAME" --location "$LOCATION" --only-show-errors >/dev/null
  local rules=(
    "Allow-HTTPS-Internet 100 TCP 443 Internet Inbound Allow"
    "Allow-SSH-Scoped 110 TCP 22 $ALLOW_SSH_IP Inbound Allow"
    "Allow-ICMP-Internet 120 ICMP '*' Internet Inbound Allow"
    "Allow-All-Out 200 '*' '*' Internet Outbound Allow"
  )
  for rule in "${rules[@]}"; do
    read -r name prio proto port src dir action <<<"$rule"
    dir=${dir:-Inbound}
    action=${action:-Allow}
    local src_prefix dest_prefix
    if [[ "$dir" == "Outbound" ]]; then
      src_prefix="*"
      dest_prefix="$src"
    else
      src_prefix="$src"
      dest_prefix="*"
    fi
    if az network nsg rule show -g "$RG_NAME" --nsg-name "$WAN_NSG_NAME" -n "$name" >/dev/null 2>&1; then
      az_with_retry az network nsg rule update -g "$RG_NAME" --nsg-name "$WAN_NSG_NAME" -n "$name" \
        --direction "$dir" --priority "$prio" --access "$action" --protocol "$proto" \
        --source-address-prefixes "$src_prefix" --source-port-ranges "*" --destination-address-prefixes "$dest_prefix" \
        --destination-port-ranges "$port" --only-show-errors >/dev/null
    else
      az_with_retry az network nsg rule create -g "$RG_NAME" --nsg-name "$WAN_NSG_NAME" -n "$name" \
        --direction "$dir" --priority "$prio" --access "$action" --protocol "$proto" \
        --source-address-prefixes "$src_prefix" --source-port-ranges "*" --destination-address-prefixes "$dest_prefix" \
        --destination-port-ranges "$port" --only-show-errors >/dev/null
    fi
  done
  az_with_retry az network nic update -g "$RG_NAME" -n "$WAN_NIC_NAME" --network-security-group "$WAN_NSG_NAME" --only-show-errors >/dev/null
}

ensure_lan_nsg() {
  echo "[NSG-LAN] Ensuring NSG $LAN_NSG_NAME"
  az_with_retry az network nsg create -g "$RG_NAME" -n "$LAN_NSG_NAME" --location "$LOCATION" --only-show-errors >/dev/null
  # Allow all from VNet, allow from FortiGate LAN IP, deny internet inbound
  local rules=(
    "Allow-VNet 100 '*' '*' VirtualNetwork Inbound Allow"
    "Allow-FGT-LAN 110 '*' '*' $FGT_LAN_IP Inbound Allow"
    "Deny-Internet-In 400 '*' '*' Internet Inbound Deny"
  )
  for rule in "${rules[@]}"; do
    read -r name prio proto port src dir action <<<"$rule"
    action=${action:-Allow}
    if az network nsg rule show -g "$RG_NAME" --nsg-name "$LAN_NSG_NAME" -n "$name" >/dev/null 2>&1; then
      az_with_retry az network nsg rule update -g "$RG_NAME" --nsg-name "$LAN_NSG_NAME" -n "$name" \
        --direction "${dir:-Inbound}" --priority "$prio" --access "$action" --protocol "$proto" \
        --source-address-prefixes "$src" --source-port-ranges "*" --destination-address-prefixes "*" \
        --destination-port-ranges "$port" --only-show-errors >/dev/null
    else
      az_with_retry az network nsg rule create -g "$RG_NAME" --nsg-name "$LAN_NSG_NAME" -n "$name" \
        --direction "${dir:-Inbound}" --priority "$prio" --access "$action" --protocol "$proto" \
        --source-address-prefixes "$src" --source-port-ranges "*" --destination-address-prefixes "*" \
        --destination-port-ranges "$port" --only-show-errors >/dev/null
    fi
  done
  # Attach to hub LAN subnet
  az_with_retry az network vnet subnet update -g "$RG_NAME" --vnet-name "$HUB_VNET_NAME" -n "$SUBNET_FW_LAN" --network-security-group "$LAN_NSG_NAME" --only-show-errors >/dev/null
  # Attach to all spoke subnets if present
  if az network vnet show -g "$RG_NAME" -n "$SPOKE_VNET_NAME" >/dev/null 2>&1; then
    az network vnet subnet list -g "$RG_NAME" --vnet-name "$SPOKE_VNET_NAME" --query "[].name" -o tsv | while read -r subnet_name; do
      [[ -z "$subnet_name" ]] && continue
      az_with_retry az network vnet subnet update -g "$RG_NAME" --vnet-name "$SPOKE_VNET_NAME" -n "$subnet_name" --network-security-group "$LAN_NSG_NAME" --only-show-errors >/dev/null
    done
  fi
}

apply_bootstrap() {
  echo "[BOOTSTRAP] Applying FortiGate bootstrap via custom data + run-command"
  local script_content
  script_content=$(cat <<'SCRIPT'
cat <<'CFG' >/tmp/fgt-bootstrap.conf
CFG_CONTENT
CFG
if command -v fnsysctl >/dev/null 2>&1; then
  fnsysctl mv /tmp/fgt-bootstrap.conf /config/init.conf || true
else
  mv /tmp/fgt-bootstrap.conf /tmp/init.conf || true
fi
SCRIPT
)
  script_content="${script_content/CFG_CONTENT/$BOOTSTRAP_CONFIG}"
  az_with_retry az vm run-command invoke \
    -g "$RG_NAME" -n "$FGT_VM_NAME" \
    --command-id RunShellScript \
    --scripts "$script_content" >/dev/null || echo "[WARN] Bootstrap run-command may not be supported on this image"
}

ensure_default_routing() {
  echo "[ROUTING] Ensuring default route table $ROUTE_TABLE_DEFAULT"
  if ! az network route-table show -g "$RG_NAME" -n "$ROUTE_TABLE_DEFAULT" >/dev/null 2>&1; then
    az_with_retry az network route-table create -g "$RG_NAME" -n "$ROUTE_TABLE_DEFAULT" --location "$LOCATION" --only-show-errors >/dev/null
  fi
  if az network route-table route show -g "$RG_NAME" --route-table-name "$ROUTE_TABLE_DEFAULT" -n "$ROUTE_NAME_DEFAULT" >/dev/null 2>&1; then
    az_with_retry az network route-table route update -g "$RG_NAME" --route-table-name "$ROUTE_TABLE_DEFAULT" -n "$ROUTE_NAME_DEFAULT" \
      --address-prefix 0.0.0.0/0 --next-hop-type VirtualAppliance --next-hop-ip-address "$FGT_LAN_IP" --only-show-errors >/dev/null
  else
    az_with_retry az network route-table route create -g "$RG_NAME" --route-table-name "$ROUTE_TABLE_DEFAULT" -n "$ROUTE_NAME_DEFAULT" \
      --address-prefix 0.0.0.0/0 --next-hop-type VirtualAppliance --next-hop-ip-address "$FGT_LAN_IP" --only-show-errors >/dev/null
  fi
  if az network vnet show -g "$RG_NAME" -n "$SPOKE_VNET_NAME" >/dev/null 2>&1; then
    az network vnet subnet list -g "$RG_NAME" --vnet-name "$SPOKE_VNET_NAME" --query "[].name" -o tsv | while read -r subnet_name; do
      [[ -z "$subnet_name" ]] && continue
      az_with_retry az network vnet subnet update -g "$RG_NAME" --vnet-name "$SPOKE_VNET_NAME" -n "$subnet_name" --route-table "$ROUTE_TABLE_DEFAULT" --only-show-errors >/dev/null
    done
  fi
}

check_state() {
  local failures=0
  local vm_state
  vm_state=$(az vm show -g "$RG_NAME" -n "$FGT_VM_NAME" --query "provisioningState" -o tsv 2>/dev/null || echo "missing")
  if [[ "$vm_state" != "Succeeded" ]]; then
    echo "[FAIL] FortiGate VM provisioning state: $vm_state"
    failures=$((failures+1))
  fi
  for nic in "$WAN_NIC_NAME" "$LAN_NIC_NAME"; do
    local ipf
    ipf=$(az network nic show -g "$RG_NAME" -n "$nic" --query "enableIPForwarding" -o tsv 2>/dev/null || echo "false")
    if [[ "$ipf" != "true" ]]; then
      echo "[FAIL] IP forwarding disabled on $nic; re-enabling"
      az_with_retry az network nic update -g "$RG_NAME" -n "$nic" --set enableIPForwarding=true >/dev/null || failures=$((failures+1))
    fi
  done
  local nsg
  nsg=$(az network nic show -g "$RG_NAME" -n "$WAN_NIC_NAME" --query "networkSecurityGroup.id" -o tsv 2>/dev/null || echo "")
  if [[ -z "$nsg" ]]; then
    echo "[FAIL] NSG not associated to $WAN_NIC_NAME; re-associating"
    az_with_retry az network nic update -g "$RG_NAME" -n "$WAN_NIC_NAME" --network-security-group "$WAN_NSG_NAME" --only-show-errors >/dev/null || failures=$((failures+1))
  fi
  # DNS validation (presence)
  if ! az network private-dns record-set a show -g "$RG_NAME" -z "$PRIVATE_DNS_ZONE" -n "${RECORD_FGT%%.*}" >/dev/null 2>&1; then
    echo "[FAIL] Private DNS record for FortiGate missing"; failures=$((failures+1))
  fi
  # Reachability check (best effort)
  local fqdn
  fqdn=$(az network public-ip show -g "$RG_NAME" -n "$PIP_NAME" --query "dnsSettings.fqdn" -o tsv 2>/dev/null || true)
  if [[ -n "$fqdn" ]]; then
    if ! curl -k -m 5 -s "https://$fqdn" >/dev/null 2>&1; then
      echo "[WARN] HTTPS reachability to FortiGate failed (best-effort check)."
    fi
  fi
  if (( failures > 0 )); then
    echo "[RESULT] Self-heal encountered $failures issue(s)."
    return 1
  fi
  echo "[RESULT] State healthy."
}

preflight_checks

echo "[01] Resource group"
az_with_retry az group create -n "$RG_NAME" -l "$LOCATION" --only-show-errors >/dev/null

echo "[02] Hub VNet + subnets"
if ! az network vnet show -g "$RG_NAME" -n "$HUB_VNET_NAME" >/dev/null 2>&1; then
  az_with_retry az network vnet create \
    -g "$RG_NAME" \
    -n "$HUB_VNET_NAME" \
    -l "$LOCATION" \
    --address-prefixes "$HUB_VNET_CIDR" \
    --subnet-name "$SUBNET_FW_WAN" \
    --subnet-prefixes "$SUBNET_FW_WAN_CIDR" \
    --only-show-errors >/dev/null
fi

if ! az network vnet subnet show -g "$RG_NAME" --vnet-name "$HUB_VNET_NAME" -n "$SUBNET_FW_LAN" >/dev/null 2>&1; then
  az_with_retry az network vnet subnet create \
    -g "$RG_NAME" \
    --vnet-name "$HUB_VNET_NAME" \
    -n "$SUBNET_FW_LAN" \
    --address-prefixes "$SUBNET_FW_LAN_CIDR" \
    --only-show-errors >/dev/null
fi

echo "[03] Public IP"
if ! az network public-ip show -g "$RG_NAME" -n "$PIP_NAME" >/dev/null 2>&1; then
  az_with_retry az network public-ip create \
    -g "$RG_NAME" \
    -n "$PIP_NAME" \
    --sku Standard \
    --allocation-method Static \
    --version IPv4 \
    --only-show-errors >/dev/null
fi

ensure_dns_public_label

echo "[04] WAN NIC"
if ! az network nic show -g "$RG_NAME" -n "$WAN_NIC_NAME" >/dev/null 2>&1; then
  az_with_retry az network nic create \
    -g "$RG_NAME" \
    -n "$WAN_NIC_NAME" \
    --vnet-name "$HUB_VNET_NAME" \
    --subnet "$SUBNET_FW_WAN" \
    --public-ip-address "$PIP_NAME" \
    --ip-forwarding true \
    --only-show-errors >/dev/null
fi

echo "[05] LAN NIC"
if ! az network nic show -g "$RG_NAME" -n "$LAN_NIC_NAME" >/dev/null 2>&1; then
  az_with_retry az network nic create \
    -g "$RG_NAME" \
    -n "$LAN_NIC_NAME" \
    --vnet-name "$HUB_VNET_NAME" \
    --subnet "$SUBNET_FW_LAN" \
    --private-ip-address "$FGT_LAN_IP" \
    --ip-forwarding true \
    --only-show-errors >/dev/null
fi

echo "[05b] Ensure IP forwarding on NICs"
az_with_retry az network nic update -g "$RG_NAME" -n "$WAN_NIC_NAME" --set enableIPForwarding=true >/dev/null
az_with_retry az network nic update -g "$RG_NAME" -n "$LAN_NIC_NAME" --set enableIPForwarding=true >/dev/null

ensure_wan_nsg
ensure_lan_nsg

echo "[06] FortiGate VM"
if ! az vm show -g "$RG_NAME" -n "$FGT_VM_NAME" >/dev/null 2>&1; then
  accept_fortinet_terms
  tmp_userdata=$(mktemp)
  printf "%s\n" "$BOOTSTRAP_CONFIG" > "$tmp_userdata"
  az_with_retry az vm create \
    -g "$RG_NAME" \
    -n "$FGT_VM_NAME" \
    --image "$FGT_IMAGE" \
    --size Standard_F4s_v2 \
    --admin-username "$FGT_ADMIN_USER" \
    --admin-password "$FGT_ADMIN_PASSWORD" \
    --nics "$WAN_NIC_NAME" "$LAN_NIC_NAME" \
    --os-disk-size-gb 60 \
    --storage-sku StandardSSD_LRS \
    --plan-publisher "$PLAN_PUBLISHER" \
    --plan-product "$PLAN_PRODUCT" \
    --plan-name "$PLAN_NAME" \
    --custom-data "$tmp_userdata" \
    --only-show-errors >/dev/null
  rm -f "$tmp_userdata"
else
  echo "[INFO] FortiGate VM exists, ensuring plan metadata is set"
  az_with_retry az vm update -g "$RG_NAME" -n "$FGT_VM_NAME" \
    --set plan.publisher="$PLAN_PUBLISHER" plan.product="$PLAN_PRODUCT" plan.name="$PLAN_NAME" >/dev/null || true
fi

echo "[07] Apply FortiGate bootstrap (post-deploy)"
apply_bootstrap

echo "[08] Hub-Spoke default route via FortiGate"
ensure_default_routing

echo "[09] DNS configuration"
SPOKE_VM_IP=$(az vm list-ip-addresses -g "$RG_NAME" -n "vm-spoke-app-01" --query "[0].virtualMachine.network.privateIpAddresses[0]" -o tsv 2>/dev/null || true)
ensure_private_dns

echo "[10] Self-heal checks"
check_state

FGT_PIP=$(az network public-ip show -g "$RG_NAME" -n "$PIP_NAME" --query "ipAddress" -o tsv)
FGT_FQDN=$(az network public-ip show -g "$RG_NAME" -n "$PIP_NAME" --query "dnsSettings.fqdn" -o tsv)

echo
echo "=== HUB + FGT READY ==="
echo "RG:        $RG_NAME"
echo "Hub VNet:  $HUB_VNET_NAME ($HUB_VNET_CIDR)"
echo "FGT VM:    $FGT_VM_NAME"
echo "  User:    $FGT_ADMIN_USER"
echo "  Pass:    $FGT_ADMIN_PASSWORD"
echo "  LAN IP:  $FGT_LAN_IP"
echo "  PIP:     $FGT_PIP"
echo "  FQDN:    $FGT_FQDN"
