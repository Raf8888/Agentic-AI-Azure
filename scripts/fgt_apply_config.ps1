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

$adminUser = $secret.fgtAdminUsername
$adminPass = $secret.fgtAdminPassword
if ([string]::IsNullOrWhiteSpace($adminUser)) { $adminUser = 'fortiadmin' }
if ([string]::IsNullOrWhiteSpace($adminPass)) { $adminPass = 'Welcome12345' }

function Get-SubnetMaskFromCidr {
  param([Parameter(Mandatory)] [string] $Cidr)
  $parts = $Cidr.Split('/')
  if ($parts.Count -ne 2) { return '255.255.255.0' }
  $prefix = [int]$parts[1]
  $maskInt = [uint32]0
  if ($prefix -eq 0) { $maskInt = 0 }
  else { $maskInt = [uint32]([uint32]0xFFFFFFFF -shl (32 - $prefix)) }
  [System.Net.IPAddress]::new([bitconverter]::GetBytes([uint32]([System.Net.IPAddress]::HostToNetworkOrder([int]$maskInt)))).ToString()
}

function Get-GatewayFromCidr {
  param([Parameter(Mandatory)] [string] $Cidr)
  $parts = $Cidr.Split('/')
  $ipParts = $parts[0].Split('.')
  if ($ipParts.Count -eq 4) { return "{0}.{1}.{2}.1" -f $ipParts[0],$ipParts[1],$ipParts[2] }
  return '10.100.0.1'
}

$lanMask = Get-SubnetMaskFromCidr -Cidr $lanPrefix
$wanGateway = Get-GatewayFromCidr -Cidr $wanPrefix

$cfgPath = Join-Path $outDir 'fortigate-fw-config.txt'

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
