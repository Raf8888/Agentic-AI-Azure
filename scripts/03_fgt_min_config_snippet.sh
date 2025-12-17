#!/usr/bin/env bash
set -euo pipefail

RG_NAME="rg-fgt-hubspoke"
PIP_NAME="pip-fgt-hub"

FGT_LAN_IP=$(az network nic show -g "$RG_NAME" -n "nic-fgt-lan" --query "ipConfigurations[0].privateIpAddress" -o tsv 2>/dev/null || true)
if [ -z "$FGT_LAN_IP" ]; then
  echo "[ERROR] Unable to discover FortiGate LAN IP from nic-fgt-lan" >&2
  exit 1
fi
FGT_LAN_MASK="255.255.255.0"
WAN_GATEWAY_IP="10.100.0.1"
SPOKE_SUBNET="10.101.1.0/24"

FGT_PIP=$(az network public-ip show -g "$RG_NAME" -n "$PIP_NAME" --query ipAddress -o tsv)

cat > fortigate-hubspoke-config.txt <<EOF
# Minimal FortiGate config for Azure hub-spoke lab

config system interface
    edit "port2"
        set ip $FGT_LAN_IP $FGT_LAN_MASK
        set allowaccess ping https ssh
    next
end

config router static
    edit 1
        set dst 0.0.0.0 0.0.0.0
        set gateway $WAN_GATEWAY_IP
        set device "port1"
    next
end

config firewall address
    edit "spoke-subnet"
        set subnet $SPOKE_SUBNET
    next
end

config firewall policy
    edit 1
        set name "LAN-to-Internet"
        set srcintf "port2"
        set dstintf "port1"
        set srcaddr "spoke-subnet"
        set dstaddr "all"
        set action accept
        set schedule "always"
        set service "ALL"
        set nat enable
    next
end
EOF

echo "Config saved to fortigate-hubspoke-config.txt"
echo "FortiGate PIP: $FGT_PIP"
