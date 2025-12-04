# Azure FortiGate Hub-Spoke Lab Architecture

## Topology
- Region: westeurope; Resource group: rg-fgt-hubspoke
- Hub VNet: vnet-hub-fgt (10.100.0.0/16)
  - snet-fw-wan (10.100.0.0/24) - FortiGate port1 (WAN) with public IP pip-fgt-hub
  - snet-fw-lan (10.100.1.0/24) - FortiGate port2 (LAN) static IP 10.100.1.4
- Spoke VNet: vnet-spoke-app (10.101.0.0/16)
  - snet-spoke-app (10.101.1.0/24) - workload VM vm-spoke-app-01
- Peering: hub-to-spoke and spoke-to-hub with allowVnetAccess=true and allowForwardedTraffic=true
- Routing: route table rt-spoke-via-fgt on snet-spoke-app with `0.0.0.0/0 -> VirtualAppliance 10.100.1.4`

## Traffic flow
1. Spoke VM sends default traffic to route table, forwarded to FortiGate LAN IP 10.100.1.4 (port2).
2. FortiGate forwards to Azure default gateway 10.100.0.1 on port1 (WAN) via static route.
3. Return traffic flows back over hub-spoke peering; allowForwardedTraffic permits forwarding through the firewall.

## Workflow orchestration
- Stage 1 (`scripts/01_hub_fgt_deploy.sh`): Creates RG, hub VNet/subnets, public IP/DNS, NICs, FortiGate VM. Outputs public IP, FQDN, LAN IP.
- Stage 2 (`scripts/02_spoke_and_peering.sh`): Uses hub VNet to build the spoke VNet + VM, creates hub-to-spoke peering, and applies route table pointing to FortiGate LAN IP.
- Stage 3a (`scripts/03_fgt_min_config_snippet.sh`): Reads public IP/FQDN and writes `fortigate-hubspoke-config.txt` with minimal LAN->WAN policy and default route.
- Stage 3b (`scripts/04_validate_env.sh`): Confirms provisioning state for RG, VNets, VMs, route table/route, subnet association, and public IP/FQDN; exits non-zero on critical gaps.
- Artifact: Workflow uploads `fortigate-hubspoke-config.txt` for FortiGate onboarding.

## Dependencies between stages
- Stage 2 requires Stage 1 hub VNet name/id for peering and FortiGate LAN IP for the route table.
- Stage 3a needs Stage 1 public IP/FQDN to populate the config snippet.
- Stage 3b relies on all previous resources to validate and summarize the deployment.
