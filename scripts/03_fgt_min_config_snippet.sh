#!/usr/bin/env bash
set -euo pipefail

RESOURCE_GROUP="rg-fgt-hubspoke"
PUBLIC_IP_NAME="pip-fgt-hub"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
OUTPUT_FILE="${OUTPUT_FILE:-${REPO_ROOT}/fortigate-hubspoke-config.txt}"

log() { echo "[INFO] $*"; }

log "Retrieving FortiGate public IP and FQDN"
PUB_IP=$(az network public-ip show --only-show-errors -g "$RESOURCE_GROUP" -n "$PUBLIC_IP_NAME" --query "ipAddress" -o tsv)
FQDN=$(az network public-ip show --only-show-errors -g "$RESOURCE_GROUP" -n "$PUBLIC_IP_NAME" --query "dnsSettings.fqdn" -o tsv)

if [[ -z "${PUB_IP}" || -z "${FQDN}" ]]; then
  echo "[ERROR] Unable to retrieve FortiGate public IP/FQDN. Check deployment." >&2
  exit 1
fi

log "Writing minimal FortiGate config snippet to $OUTPUT_FILE"
cat > "$OUTPUT_FILE" <<'EOF'
config system interface
    edit "port2"
        set mode static
        set ip 10.100.1.4 255.255.255.0
        set allowaccess ping https ssh
    next
end

config router static
    edit 0
        set dst 0.0.0.0 0.0.0.0
        set gateway 10.100.0.1
        set device "port1"
    next
end

config firewall address
    edit "spoke-10.101.1.0_24"
        set subnet 10.101.1.0 255.255.255.0
    next
end

config firewall policy
    edit 0
        set name "LAN-to-WAN"
        set srcintf "port2"
        set dstintf "port1"
        set srcaddr "all"
        set dstaddr "all"
        set action accept
        set nat enable
        set schedule "always"
        set service "ALL"
    next
end
EOF

log "Config snippet generated"
echo "Config file: $OUTPUT_FILE"
echo "FortiGate public IP: $PUB_IP"
echo "FortiGate FQDN: $FQDN"
