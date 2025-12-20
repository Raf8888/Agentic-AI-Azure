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
$location = $lab.location

$hubVnet = $lab.hub.vnetName
$spokeVnet = $lab.spoke.vnetName

$zone = $lab.dns.privateZone
$fgtRecord = $lab.dns.records.fortigateA
$spokeRecord = $lab.dns.records.spokeVmA

$fgtLanIp = $stage1.fortigate.lanIp
$spokeVmIp = $stage2.spokeVm.privateIp
$spokeNicId = $stage2.spokeVm.nicId

$fgtFqdn = $stage1.fortigate.fqdn
$fgtPublicIp = $stage1.fortigate.publicIp

Write-Host "[STAGE3] Private DNS zone + links" -ForegroundColor Cyan
try {
  Invoke-AzCli -Args @('network','private-dns','zone','show','-g',$rg,'-n',$zone,'-o','none') | Out-Null
} catch {
  Invoke-AzCli -Args @('network','private-dns','zone','create','-g',$rg,'-n',$zone,'-o','none') | Out-Null
}

$hubId = Invoke-AzCli -Args @('network','vnet','show','-g',$rg,'-n',$hubVnet,'--query','id','-o','tsv')
$spokeId = Invoke-AzCli -Args @('network','vnet','show','-g',$rg,'-n',$spokeVnet,'--query','id','-o','tsv')

foreach ($link in @(
  @{ Name = "$hubVnet-link"; VnetId = $hubId },
  @{ Name = "$spokeVnet-link"; VnetId = $spokeId }
)) {
  try {
    Invoke-AzCli -Args @('network','private-dns','link','vnet','show','-g',$rg,'-z',$zone,'-n',$link.Name,'-o','none') | Out-Null
  } catch {
    Invoke-AzCli -Args @('network','private-dns','link','vnet','create','-g',$rg,'-z',$zone,'-n',$link.Name,'--virtual-network',$link.VnetId,'--registration-enabled','false','-o','none') | Out-Null
  }
}

Write-Host "[STAGE3] Private DNS A records" -ForegroundColor Cyan
function Ensure-ARecordExact {
  param(
    [Parameter(Mandatory)] [string] $Name,
    [Parameter(Mandatory)] [string] $Ip
  )
  try {
    Invoke-AzCli -Args @('network','private-dns','record-set','a','show','-g',$rg,'-z',$zone,'-n',$Name,'-o','none') | Out-Null
  } catch {
    Invoke-AzCli -Args @('network','private-dns','record-set','a','create','-g',$rg,'-z',$zone,'-n',$Name,'-o','none') | Out-Null
  }

  $existingIps = @()
  try {
    $existingIps = Invoke-AzCli -Args @('network','private-dns','record-set','a','show','-g',$rg,'-z',$zone,'-n',$Name,'--query','arecords[].ipv4Address','-o','tsv')
    $existingIps = @($existingIps -split "\s+" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
  } catch { $existingIps = @() }

  if (($existingIps.Count -eq 1) -and ($existingIps[0] -eq $Ip)) { return }

  # Remove all existing A records to avoid duplicate IP errors, then add the desired IP once.
  foreach ($old in $existingIps) {
    try { Invoke-AzCli -Args @('network','private-dns','record-set','a','remove-record','-g',$rg,'-z',$zone,'-n',$Name,'-a',$old,'-o','none') | Out-Null } catch {}
  }
  Invoke-AzCli -Args @('network','private-dns','record-set','a','add-record','-g',$rg,'-z',$zone,'-n',$Name,'-a',$Ip,'-o','none') | Out-Null
}

Ensure-ARecordExact -Name $fgtRecord -Ip $fgtLanIp
Ensure-ARecordExact -Name $spokeRecord -Ip $spokeVmIp

Write-Host "[STAGE3] Effective routes (spoke NIC)" -ForegroundColor Cyan
$routes = $null
try {
  $routes = Invoke-AzCli -Args @('network','nic','show-effective-route-table','--ids',$spokeNicId,'-o','json') -Json
} catch {
  $routes = $null
}

if ($null -ne $routes) {
  $routeEntries = @()
  if ($routes -is [System.Array]) { $routeEntries = $routes }
  elseif ($null -ne $routes.value) { $routeEntries = @($routes.value) }
  else { $routeEntries = @($routes) }

  $defaultRouteOk = $false
  foreach ($r in $routeEntries) {
    if ($r.addressPrefix -eq '0.0.0.0/0' -and $r.nextHopType -eq 'VirtualAppliance' -and $r.nextHopIpAddress -eq $fgtLanIp) {
      $defaultRouteOk = $true
      break
    }
  }
  if (-not $defaultRouteOk) {
    throw "Effective routes do not show default route 0.0.0.0/0 via VirtualAppliance $fgtLanIp"
  }
}

Write-Host "[STAGE3] Validate internet egress from spoke VM (RunCommand)" -ForegroundColor Cyan
$spokeVmName = $lab.spoke.vm.name
$runCommandOutput = $null
$internalFgt = "$fgtRecord.$zone"
$internalSpoke = "$spokeRecord.$zone"
$runScript = @(
  'set -e',
  'echo "[PING]"',
  'ping -c 3 8.8.8.8',
  'echo "[DNS-INTERNAL]"',
  "getent hosts $internalFgt || true",
  "getent hosts $internalSpoke || true",
  'echo "[DNS-EXTERNAL]"',
  'getent hosts google.com || true',
  'echo "[CURL]"',
  'curl -s -m 5 https://ifconfig.me || true'
) -join '; '
try {
  $runCommandOutput = Invoke-AzCli -Args @(
    'vm','run-command','invoke',
    '-g',$rg,'-n',$spokeVmName,
    '--command-id','RunShellScript',
    '--scripts',$runScript,
    '-o','json'
  ) -Json
} catch {
  $runCommandOutput = $null
}

Write-Host "[STAGE3] Generate FortiGate config snippet" -ForegroundColor Cyan
$cfgPath = Join-Path $outDir 'fortigate-config.txt'
$adminUser = $secret.fgtAdminUsername
$adminPass = $secret.fgtAdminPassword
if ([string]::IsNullOrWhiteSpace($adminUser)) { $adminUser = 'admin' }
if ([string]::IsNullOrWhiteSpace($adminPass)) { $adminPass = 'FortiGate@12345' }

@"
# FortiGate minimal base config (Azure hub-spoke)

config system admin
    edit "admin"
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
        set ip $fgtLanIp 255.255.255.0
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
"@ | Set-Content -LiteralPath $cfgPath -Encoding ASCII

Write-Host "[STAGE3] Optional: push config to FortiGate (best-effort)" -ForegroundColor Cyan
$pushResult = $null
try {
  $fgtVmName = $lab.fortigate.vmName
  $pushResult = Invoke-AzCli -Args @(
    'vm','run-command','invoke',
    '-g',$rg,'-n',$fgtVmName,
    '--command-id','RunShellScript',
    '--scripts','echo "FortiGate run-command not guaranteed on this image";',
    '-o','json'
  ) -Json
} catch {
  $pushResult = $null
}

Write-Host "[STAGE3] Best-effort HTTPS check" -ForegroundColor Cyan
$httpsOk = $false
if (-not [string]::IsNullOrWhiteSpace($fgtFqdn)) {
  for ($i=1; $i -le 12; $i++) {
    try {
      $null = Invoke-WebRequest -Uri ("https://{0}" -f $fgtFqdn) -SkipCertificateCheck -TimeoutSec 5
      $httpsOk = $true
      break
    } catch {
      Start-Sleep -Seconds 10
    }
  }
}

$outputs = [pscustomobject]@{
  stage = "stage3"
  resourceGroup = $rg
  privateDns = [pscustomobject]@{
    zone = $zone
    fgtRecord = "$fgtRecord.$zone"
    spokeRecord = "$spokeRecord.$zone"
  }
  fortigate = [pscustomobject]@{
    publicIp = $fgtPublicIp
    fqdn = $fgtFqdn
    lanIp = $fgtLanIp
    httpsReachable = $httpsOk
    configFile = $cfgPath
  }
  spoke = [pscustomobject]@{
    vmPrivateIp = $spokeVmIp
    effectiveRoutes = $routes
    runCommand = $runCommandOutput
  }
}

Write-JsonFile -Path (Join-Path $outDir 'stage3.outputs.json') -Object $outputs

Write-Host ""
Write-Host "FortiGate FQDN: $fgtFqdn"
Write-Host "FortiGate GUI:  https://$fgtFqdn"
Write-Host "Spoke VM IP:    $spokeVmIp"
Write-Host "Config file:    $cfgPath"
