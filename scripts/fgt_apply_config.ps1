Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot/../tools/common.ps1"

$repoRoot = Get-RepoRoot
$configPath = Join-Path $repoRoot 'config/lab.json'
$outDir = Join-Path $repoRoot 'out'
Ensure-Directory -Path $outDir

Test-AzLogin

$lab = Read-JsonFile -Path $configPath
$secretJson = Get-EnvOrDefault -Name 'FGT_LAB_CONFIG' -Default '{}'
$secret = $secretJson | ConvertFrom-Json
$myCidr = Get-EnvOrDefault -Name 'MY_PUBLIC_IP_CIDR' -Default '0.0.0.0/0'

$stage1 = Read-JsonFile -Path (Join-Path $outDir 'stage1.outputs.json')
$stage2 = Read-JsonFile -Path (Join-Path $outDir 'stage2.outputs.json')

$rg = $lab.resourceGroup
$fgtVmName = $lab.fortigate.vmName
$fgtLanIp = $stage1.fortigate.lanIp
$fgtFqdn = $stage1.fortigate.fqdn

$lanPrefix = $stage1.hubVnet.lanSubnet.prefix
$wanPrefix = $lab.hub.wanSubnet.prefix
$spokeSubnet = $stage2.spokeVnet.subnet.prefix
$wanNsg = $lab.fortigate.wanNsgName

$adminUser = $secret.fgtAdminUsername
$adminPass = $secret.fgtAdminPassword
if ([string]::IsNullOrWhiteSpace($adminUser)) { $adminUser = 'fortiadmin' }
if ([string]::IsNullOrWhiteSpace($adminPass)) { $adminPass = 'Welcome12345' }
if ([string]::IsNullOrWhiteSpace($myCidr)) { $myCidr = '0.0.0.0/0' }

function Get-SubnetMaskFromCidr {
  param([Parameter(Mandatory)] [string] $Cidr)
  try {
    $parts = $Cidr.Split('/')
    if ($parts.Count -ne 2) { return '255.255.255.0' }
    $prefix = [int]$parts[1]
    if ($prefix -lt 0 -or $prefix -gt 32) { return '255.255.255.0' }
    $maskInt = [uint32]0
    if ($prefix -eq 0) { $maskInt = 0 }
    else { $maskInt = [uint32]([uint32]0xFFFFFFFF -shl (32 - $prefix)) }
    return [System.Net.IPAddress]::new([bitconverter]::GetBytes([uint32]([System.Net.IPAddress]::HostToNetworkOrder([int]$maskInt)))).ToString()
  } catch { return '255.255.255.0' }
}

function Get-GatewayFromCidr {
  param([Parameter(Mandatory)] [string] $Cidr)
  try {
    $parts = $Cidr.Split('/')
    $ipParts = $parts[0].Split('.')
    if ($ipParts.Count -eq 4) { return "{0}.{1}.{2}.1" -f $ipParts[0],$ipParts[1],$ipParts[2] }
  } catch {}
  return '10.100.0.1'
}

# Validate prefixes; fallback to lab config defaults if missing/invalid
function Get-ValidCidr {
  param([string] $Value, [string] $Fallback)
  if (-not [string]::IsNullOrWhiteSpace($Value)) {
    try { $null = Convert-CidrToRange -Cidr $Value; return $Value } catch {}
  }
  return $Fallback
}

function Resolve-SubnetPrefix {
  param(
    [string] $VnetName,
    [string] $SubnetName,
    [string] $Fallback
  )
  try {
    $subnet = Invoke-AzCli -Args @('network','vnet','subnet','show','-g',$rg,'--vnet-name',$VnetName,'-n',$SubnetName,'-o','json') -Json
    $prefixes = Get-SubnetAddressPrefixes -SubnetObj $subnet
    if ($prefixes.Count -gt 0) { return $prefixes[0] }
  } catch {}
  return $Fallback
}

# Derive LAN prefix: prefer stage1 output, otherwise actual NIC subnet, otherwise config default
if ([string]::IsNullOrWhiteSpace($lanPrefix)) {
  try {
    $lanNic = Invoke-AzCli -Args @('network','nic','show','-g',$rg,'-n',$lab.fortigate.lanNicName,'-o','json') -Json
    $lanSubnetId = $lanNic.ipConfigurations[0].subnet.id
    if (-not [string]::IsNullOrWhiteSpace($lanSubnetId)) {
      $parts = $lanSubnetId -split '/'
      $lanVnetName = $parts[$parts.Length-3]
      $lanSubnetName = $parts[$parts.Length-1]
      $lanPrefix = Resolve-SubnetPrefix -VnetName $lanVnetName -SubnetName $lanSubnetName -Fallback $lab.hub.lanSubnet.prefixStart
    }
  } catch {}
}

$lanPrefix = Get-ValidCidr -Value $lanPrefix -Fallback $lab.hub.lanSubnet.prefixStart
$wanPrefix = Get-ValidCidr -Value $wanPrefix -Fallback (Resolve-SubnetPrefix -VnetName $lab.hub.vnetName -SubnetName $lab.hub.wanSubnet.name -Fallback $lab.hub.wanSubnet.prefix)
$spokeSubnet = Get-ValidCidr -Value $spokeSubnet -Fallback (Resolve-SubnetPrefix -VnetName $lab.spoke.vnetName -SubnetName $lab.spoke.subnet.name -Fallback $lab.spoke.subnet.prefix)

$lanMask = Get-SubnetMaskFromCidr -Cidr $lanPrefix
$wanGateway = Get-GatewayFromCidr -Cidr $wanPrefix

$cfgPath = Join-Path $outDir 'fortigate-fw-config.txt'

# Ensure IPsec ports allowed on WAN NSG
Write-Host "[FW-CONFIG] Ensuring NSG rules for IPsec (UDP 500/4500)" -ForegroundColor Cyan
Invoke-AzCli -Args @('network','nsg','rule','create','-g',$rg,'--nsg-name',$wanNsg,'-n','Allow-IPsec-500','--priority','130','--direction','Inbound','--access','Allow','--protocol','Udp','--source-address-prefixes','*','--destination-port-ranges','500','-o','none') | Out-Null
Invoke-AzCli -Args @('network','nsg','rule','create','-g',$rg,'--nsg-name',$wanNsg,'-n','Allow-IPsec-4500','--priority','131','--direction','Inbound','--access','Allow','--protocol','Udp','--source-address-prefixes','*','--destination-port-ranges','4500','-o','none') | Out-Null

Write-Host "[FW-CONFIG] Rendering FortiGate CLI" -ForegroundColor Cyan

@"
# FortiGate interface + policy configuration (apply-only)

config system admin
    edit "$adminUser"
        set password $adminPass
    next
end

config system interface
    edit "port1"
        set mode dhcp
        set allowaccess ping https ssh
    next
    edit "port2"
        set mode static
        set ip $fgtLanIp $lanMask
        set allowaccess ping https ssh
    next
end

config router static
    edit 1
        set dst 0.0.0.0 0.0.0.0
        set gateway $wanGateway
        set device "port1"
    next
end

config firewall address
    edit "spoke-subnet"
        set subnet $spokeSubnet
    next
    edit "mgmt-source"
        set subnet $myCidr
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
    edit 2
        set name "WAN-to-Spoke-Mgmt"
        set srcintf "port1"
        set dstintf "port2"
        set srcaddr "mgmt-source"
        set dstaddr "spoke-subnet"
        set action accept
        set schedule "always"
        set service "HTTPS" "HTTP" "SSH"
        set nat disable
    next
end

# IPsec dial-up for FortiClient (IKEv1 aggressive + XAuth)
config user local
    edit "$adminUser"
        set type password
        set passwd "$adminPass"
    next
end
config user group
    edit "fc-group"
        set member "$adminUser"
    next
end

config vpn ipsec phase1-interface
    edit "dialup-fc"
        set interface "port1"
        set peertype any
        set proposal aes256-sha256
        set mode aggressive
        set dhgrp 14
        set xauthtype auto
        set authusrgrp "fc-group"
        set psksecret "$adminPass"
        set mode-cfg enable
        set ipv4-start-ip 10.250.250.10
        set ipv4-end-ip 10.250.250.50
        set ipv4-netmask 255.255.255.0
        set ipv4-split-include "spoke-subnet"
        set ipv4-dns-server1 8.8.8.8
        set ipv4-dns-server2 1.1.1.1
    next
end

config vpn ipsec phase2-interface
    edit "dialup-fc-p2"
        set phase1name "dialup-fc"
        set proposal aes256-sha256
        set dhgrp 14
        set src-subnet 0.0.0.0 0.0.0.0
        set dst-subnet 0.0.0.0 0.0.0.0
    next
end

config firewall policy
    edit 100
        set name "FC-to-Spoke"
        set srcintf "dialup-fc"
        set dstintf "port2"
        set srcaddr "all"
        set dstaddr "spoke-subnet"
        set action accept
        set schedule "always"
        set service "ALL"
    next
    edit 101
        set name "FC-to-Internet"
        set srcintf "dialup-fc"
        set dstintf "port1"
        set srcaddr "all"
        set dstaddr "all"
        set action accept
        set schedule "always"
        set service "ALL"
        set nat enable
    next
end
"@ | Set-Content -LiteralPath $cfgPath -Encoding ASCII

Write-Host "[FW-CONFIG] Applying FortiGate config via RunCommand" -ForegroundColor Cyan

$renderedConfig = Get-Content -LiteralPath $cfgPath -Raw
$resetScriptTemplate = @'
set -e
cat >/tmp/fgt_apply.cfg <<'EOF'
__FWO_CONFIG__
EOF
/opt/fortinet/fortimanager/bin/cli -f /tmp/fgt_apply.cfg
rc=$?
echo "CLI exit code: $rc"
exit $rc
'@

$resetScript = $resetScriptTemplate -replace '__FWO_CONFIG__', $renderedConfig

Invoke-AzCli -Args @(
  'vm','run-command','invoke',
  '-g',$rg,'-n',$fgtVmName,
  '--command-id','RunShellScript',
  '--scripts',$resetScript
) | Out-Null

Write-Host ""
Write-Host "FortiGate config applied. Use https://$fgtFqdn with $adminUser / (your secret password)."
