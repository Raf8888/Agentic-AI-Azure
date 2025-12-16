#!/usr/bin/env bash
set -euo pipefail

RG_NAME="rg-fgt-hubspoke"

echo "[VAL] Resource group contents"
az resource list -g "$RG_NAME" -o table

echo "[VAL] Hub VNet"
az network vnet show -g "$RG_NAME" -n "vnet-hub-fgt" -o table

echo "[VAL] Spoke VNet"
az network vnet show -g "$RG_NAME" -n "vnet-spoke-app" -o table

echo "[VAL] Route table"
az network route-table show -g "$RG_NAME" -n "rt-spoke-via-fgt" -o table || true

echo "[VAL] Workload VM"
az vm show -g "$RG_NAME" -n "vm-spoke-app-01" -d -o table || true

echo "[VAL] Effective routes (workload NIC)"
NIC_ID=$(az vm show -g "$RG_NAME" -n "vm-spoke-app-01" --query "networkProfile.networkInterfaces[0].id" -o tsv || echo "")
if [ -n "$NIC_ID" ]; then
  az network nic show-effective-route-table --ids "$NIC_ID" -o table || true
fi

echo "[VAL] Done"
