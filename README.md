# Azure FortiGate Hub-Spoke Lab (GitHub Actions)

Fully automated lab that builds a hub-spoke topology in **westeurope** with a FortiGate firewall in the hub, a spoke VNet with a workload VM, hub-to-spoke peering, and a default route from the spoke through the FortiGate. Everything runs unattended via Bash + Azure CLI scripts orchestrated by GitHub Actions.

## What gets deployed
- Resource group `rg-fgt-hubspoke`
- Hub VNet `vnet-hub-fgt` (10.100.0.0/16) with `snet-fw-wan` (10.100.0.0/24) and `snet-fw-lan` (10.100.1.0/24)
- FortiGate BYOL VM `vm-fgt-hub` with public IP `pip-fgt-hub` (DNS label `acn-fgt-hub-westeurope` by default), WAN NIC in `snet-fw-wan`, LAN NIC static IP `10.100.1.4` in `snet-fw-lan`
- Spoke VNet `vnet-spoke-app` (10.101.0.0/16) with subnet `snet-spoke-app` (10.101.1.0/24) and workload VM `vm-spoke-app-01`
- Hub-to-spoke peering with forwarded traffic allowed, route table `rt-spoke-via-fgt` sending `0.0.0.0/0` to FortiGate LAN `10.100.1.4`
- Generated FortiGate CLI snippet for LAN->WAN NAT and default route via Azure gateway `10.100.0.1`

## GitHub secret for Azure login
Create a repository secret named `AZURE_CREDENTIALS` containing a service principal JSON (Contributor on the subscription is sufficient):

```json
{
  "clientId": "<appId>",
  "clientSecret": "<password>",
  "subscriptionId": "<subscriptionId>",
  "tenantId": "<tenantId>",
  "activeDirectoryEndpointUrl": "https://login.microsoftonline.com",
  "resourceManagerEndpointUrl": "https://management.azure.com/",
  "activeDirectoryGraphResourceId": "https://graph.windows.net/",
  "sqlManagementEndpointUrl": "https://management.core.windows.net:8443/",
  "galleryEndpointUrl": "https://gallery.azure.com/",
  "managementEndpointUrl": "https://management.core.windows.net/"
}
```

## Repository contents
- `scripts/01_hub_fgt_deploy.sh` - RG, hub VNet/subnets, public IP, NICs with IP forwarding, FortiGate BYOL VM (accepts marketplace terms automatically)
- `scripts/02_spoke_and_peering.sh` - Spoke VNet/subnet, workload NIC + VM, hub-to-spoke peering, route table with default route via FortiGate LAN
- `scripts/03_fgt_min_config_snippet.sh` - Reads FortiGate public IP/FQDN, writes `fortigate-hubspoke-config.txt` with minimal CLI snippet
- `scripts/04_validate_env.sh` - Validates RG, VNets, VMs, route table/route, subnet association, and public IP/FQDN; prints a parseable summary table
- `.github/workflows/azure-fgt-lab.yml` - Orchestrates all stages end-to-end and uploads the FortiGate config artifact
- `azure-fgt-lab-architecture.md` - Topology description and workflow hand-offs

All scripts are non-interactive (`set -euo pipefail`) and intended to be rerunnable where Azure allows.

## Running the workflow
1. Add the `AZURE_CREDENTIALS` secret as above.
2. Push to `master` or choose **Actions -> azure-fgt-lab.yml -> Run workflow** for manual dispatch.
3. Jobs run in order: `deploy_hub_fgt` (hub + FortiGate), `deploy_spoke_routing` (spoke + routing), `generate_and_validate` (config snippet + validation + artifact upload).
4. Download the `fortigate-config` artifact to apply the FortiGate CLI snippet after the run succeeds.

## Notes
- Region is fixed to `westeurope`; adjust the variables at the top of the scripts if you need another region/DNS label/VM size.
- The service principal must be able to accept the Fortinet BYOL marketplace terms (handled automatically in Stage 1).
- Passwords are lab-only defaults; rotate for any persistent use. 
