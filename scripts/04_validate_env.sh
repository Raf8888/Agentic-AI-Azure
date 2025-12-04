#!/usr/bin/env bash
set -euo pipefail

RESOURCE_GROUP="rg-fgt-hubspoke"
HUB_VNET="vnet-hub-fgt"
SPOKE_VNET="vnet-spoke-app"
HUB_VM="vm-fgt-hub"
SPOKE_VM="vm-spoke-app-01"
ROUTE_TABLE="rt-spoke-via-fgt"
ROUTE_NAME="default-via-fgt"
EXPECTED_NEXT_HOP="10.100.1.4"
PUBLIC_IP_NAME="pip-fgt-hub"

errors=0
summary=()

log() { echo "[INFO] $*"; }
fail() { echo "[FAIL] $*"; errors=$((errors+1)); }
add_summary() { summary+=("$1|$2|$3"); }

log "Validating resource group"
if az group show --only-show-errors -n "$RESOURCE_GROUP" >/dev/null 2>&1; then
  add_summary "resource_group" "ok" "$RESOURCE_GROUP"
else
  fail "Resource group $RESOURCE_GROUP missing"
  add_summary "resource_group" "missing" "not found"
fi

log "Validating VNets"
for vnet in "$HUB_VNET" "$SPOKE_VNET"; do
  state=$(az network vnet show --only-show-errors -g "$RESOURCE_GROUP" -n "$vnet" --query provisioningState -o tsv 2>/dev/null || true)
  if [[ "$state" == "Succeeded" ]]; then
    add_summary "${vnet}" "Succeeded" "provisioned"
  else
    fail "VNet $vnet not found or not succeeded (state=$state)"
    add_summary "${vnet}" "${state:-missing}" "not ready"
  fi
done

log "Validating VMs"
for vm in "$HUB_VM" "$SPOKE_VM"; do
  state=$(az vm show --only-show-errors -g "$RESOURCE_GROUP" -n "$vm" --query provisioningState -o tsv 2>/dev/null || true)
  if [[ "$state" == "Succeeded" ]]; then
    add_summary "${vm}" "Succeeded" "provisioned"
  else
    fail "VM $vm not found or not succeeded (state=$state)"
    add_summary "${vm}" "${state:-missing}" "not ready"
  fi
done

log "Validating route table and default route"
rt_state=$(az network route-table show --only-show-errors -g "$RESOURCE_GROUP" -n "$ROUTE_TABLE" --query provisioningState -o tsv 2>/dev/null || true)
if [[ "$rt_state" == "Succeeded" ]]; then
  next_hop=$(az network route-table route show --only-show-errors -g "$RESOURCE_GROUP" --route-table-name "$ROUTE_TABLE" -n "$ROUTE_NAME" --query nextHopIpAddress -o tsv 2>/dev/null || true)
  hop_type=$(az network route-table route show --only-show-errors -g "$RESOURCE_GROUP" --route-table-name "$ROUTE_TABLE" -n "$ROUTE_NAME" --query nextHopType -o tsv 2>/dev/null || true)
  if [[ "$hop_type" == "VirtualAppliance" && "$next_hop" == "$EXPECTED_NEXT_HOP" ]]; then
    add_summary "route_default" "ok" "${hop_type}:${next_hop}"
  else
    fail "Route $ROUTE_NAME missing or incorrect (type=$hop_type hop=$next_hop)"
    add_summary "route_default" "invalid" "expected ${EXPECTED_NEXT_HOP}"
  fi
  subnet_rt=$(az network vnet subnet show --only-show-errors -g "$RESOURCE_GROUP" --vnet-name "$SPOKE_VNET" -n "snet-spoke-app" --query routeTable.id -o tsv 2>/dev/null || true)
  if [[ -z "$subnet_rt" ]]; then
    fail "Route table $ROUTE_TABLE not associated to subnet snet-spoke-app"
    add_summary "route_table_assoc" "missing" "not associated"
  else
    add_summary "route_table_assoc" "ok" "$subnet_rt"
  fi
else
  fail "Route table $ROUTE_TABLE missing or not succeeded"
  add_summary "route_default" "missing" "route table not found"
  add_summary "route_table_assoc" "missing" "route table not found"
fi

log "Validating public IP"
pub_ip=$(az network public-ip show --only-show-errors -g "$RESOURCE_GROUP" -n "$PUBLIC_IP_NAME" --query ipAddress -o tsv 2>/dev/null || true)
fqdn=$(az network public-ip show --only-show-errors -g "$RESOURCE_GROUP" -n "$PUBLIC_IP_NAME" --query dnsSettings.fqdn -o tsv 2>/dev/null || true)
if [[ -n "$pub_ip" && -n "$fqdn" ]]; then
  add_summary "public_ip" "ok" "$pub_ip"
  add_summary "public_fqdn" "ok" "$fqdn"
else
  fail "Public IP $PUBLIC_IP_NAME missing or incomplete"
  add_summary "public_ip" "missing" "no ip/fqdn"
fi

log "Validation summary (ITEM|STATUS|DETAIL)"
printf "%s\n" "ITEM|STATUS|DETAIL"
for entry in "${summary[@]}"; do
  IFS='|' read -r key status detail <<< "$entry"
  printf "%s|%s|%s\n" "$key" "$status" "$detail"
done

if (( errors > 0 )); then
  echo "[RESULT] Validation failed with $errors issue(s)." >&2
  exit 1
fi

echo "[RESULT] Validation succeeded."
