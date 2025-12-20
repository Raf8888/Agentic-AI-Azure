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

$location = $lab.location
$rg = $lab.resourceGroup
$hubVnet = $lab.hub.vnetName
$hubCidr = $lab.hub.addressSpace
$spokeSubnetPrefix = $lab.spoke.subnet.prefix

$pipName = $lab.fortigate.pipName
$fgtVm = $lab.fortigate.vmName
$wanNic = $lab.fortigate.wanNicName
$lanNic = $lab.fortigate.lanNicName
$desiredLanIp = $lab.fortigate.lanIp

$imageUrn = $lab.fortigate.imageUrn
$planPublisher = $lab.fortigate.plan.publisher
$planProduct = $lab.fortigate.plan.product
$planName = $lab.fortigate.plan.name

$wanSubnetDesiredName = $lab.hub.wanSubnet.name
$wanSubnetDesiredPrefix = $lab.hub.wanSubnet.prefix
$lanSubnetName = $lab.hub.lanSubnet.name
$lanStart = $lab.hub.lanSubnet.prefixStart
$lanMax = [int]$lab.hub.lanSubnet.prefixMaxOctet

$wanNsg = $lab.fortigate.wanNsgName
$lanNsg = $lab.fortigate.lanNsgName

$dnsLabel = $secret.fgtPublicDnsLabel
if ([string]::IsNullOrWhiteSpace($dnsLabel)) {
  $runId = Get-EnvOrDefault -Name 'GITHUB_RUN_ID' -Default 'local'
  $dnsLabel = ("fgt-{0}-{1}" -f $runId, $location).ToLower().Replace('_','').Replace('.','-')
  if ($dnsLabel.Length -gt 63) { $dnsLabel = $dnsLabel.Substring(0,63) }
}

Write-Host "[STAGE1] Preflight" -ForegroundColor Cyan
Write-Host "Image URN: $imageUrn"
Write-Host "Plan:      publisher=$planPublisher product=$planProduct name=$planName"
Write-Host "WAN desired: $wanSubnetDesiredName ($wanSubnetDesiredPrefix)"
Write-Host "LAN desired: $lanSubnetName (start=$lanStart)"
Write-Host "LAN IP desired: $desiredLanIp"

Write-Host "[STAGE1] Ensure RG" -ForegroundColor Cyan
Invoke-AzCli -Args @('group','create','-n',$rg,'-l',$location,'-o','none') | Out-Null

Write-Host "[STAGE1] Ensure Hub VNet" -ForegroundColor Cyan
try {
  Invoke-AzCli -Args @('network','vnet','show','-g',$rg,'-n',$hubVnet,'-o','none') | Out-Null
} catch {
  Invoke-AzCli -Args @('network','vnet','create','-g',$rg,'-n',$hubVnet,'-l',$location,'--address-prefixes',$hubCidr,'-o','none') | Out-Null
}

Write-Host "[STAGE1] Subnets (overlap-safe)" -ForegroundColor Cyan
$existingSubnets = Get-HubSubnets -ResourceGroup $rg -VnetName $hubVnet

function Get-SubnetId {
  param([Parameter(Mandatory)] [string] $SubnetName)
  $subId = Invoke-AzCli -Args @('network','vnet','subnet','show','-g',$rg,'--vnet-name',$hubVnet,'-n',$SubnetName,'--query','id','-o','tsv')
  return $subId
}


function Ensure-SubnetReady {
  param(
    [Parameter(Mandatory)] [string] $SubnetName,
    [Parameter(Mandatory)] [string] $Prefix,
    [switch] $AllowPrefixMismatch
  )
  for ($i=1; $i -le 5; $i++) {
    try {
      $check = Invoke-AzCli -Args @('network','vnet','subnet','show','-g',$rg,'--vnet-name',$hubVnet,'-n',$SubnetName,'-o','json') -Json
      $prefixes = Get-SubnetAddressPrefixes -SubnetObj $check
      if ($prefixes -contains $Prefix) { return }
      if ($AllowPrefixMismatch) {
        Write-Host ("[WARN] Subnet {0} exists with prefix {1}; reusing existing prefix instead of changing to {2}" -f $SubnetName, ($prefixes -join ','), $Prefix) -ForegroundColor Yellow
        return
      }
      throw "prefix mismatch. Expected=$Prefix Actual=$($prefixes -join ',')"
    } catch {
      # If not found, try to create once per loop
      try {
        Invoke-AzCli -Args @('network','vnet','subnet','create','-g',$rg,'--vnet-name',$hubVnet,'-n',$SubnetName,'--address-prefixes',$Prefix,'-o','none') | Out-Null
      } catch {
        if ($AllowPrefixMismatch -and $_.Exception.Message -match 'InUsePrefixCannotBeDeleted') {
          Write-Host ("[WARN] Subnet {0} has active allocations; keeping existing prefix. Skipping create." -f $SubnetName) -ForegroundColor Yellow
          return
        }
        Write-Host "[WARN] subnet create attempt failed: $($_.Exception.Message)" -ForegroundColor Yellow
      }
      if ($i -eq 5) { throw "Subnet $SubnetName (prefix $Prefix) not ready after retries. Last error: $($_.Exception.Message)" }
      Write-Host "[WARN] Subnet $SubnetName not ready (attempt $i/5); retrying show..." -ForegroundColor Yellow
      Start-Sleep -Seconds 5
    }
  }
}

function Get-SubnetInfoFromNic {
  param(
    [Parameter(Mandatory)] [string] $NicName
  )
  $subnetId = $null
  try {
    $subnetId = Invoke-AzCli -Args @('network','nic','show','-g',$rg,'-n',$NicName,'--query','ipConfigurations[0].subnet.id','-o','tsv')
  } catch { $subnetId = $null }
  if ([string]::IsNullOrWhiteSpace($subnetId)) { return $null }

  $subnet = Invoke-AzCli -Args @('network','vnet','subnet','show','--ids',$subnetId,'-o','json') -Json
  $prefixes = Get-SubnetAddressPrefixes -SubnetObj $subnet
  $prefix = ($prefixes | Select-Object -First 1)
  if ([string]::IsNullOrWhiteSpace($prefix)) { throw "Subnet for NIC $NicName has empty prefix" }
  return [pscustomobject]@{ Name = $subnet.name; Prefix = $prefix; Id = $subnetId }
}

# Force-create desired WAN/LAN subnets up front (idempotent; Azure returns existing if already present)
try {
  Invoke-AzCli -Args @('network','vnet','subnet','create','-g',$rg,'--vnet-name',$hubVnet,'-n',$wanSubnetDesiredName,'--address-prefixes',$wanSubnetDesiredPrefix,'-o','none') | Out-Null
} catch {
  Write-Host "[WARN] Pre-create WAN subnet attempt: $($_.Exception.Message)" -ForegroundColor Yellow
}
try {
  Invoke-AzCli -Args @('network','vnet','subnet','create','-g',$rg,'--vnet-name',$hubVnet,'-n',$lanSubnetName,'--address-prefixes',$lanStart,'-o','none') | Out-Null
} catch {
  Write-Host "[WARN] Pre-create LAN subnet attempt: $($_.Exception.Message)" -ForegroundColor Yellow
}

# If desired WAN subnet exists, it must match the desired prefix
try {
  $desiredWanSubnet = Invoke-AzCli -Args @('network','vnet','subnet','show','-g',$rg,'--vnet-name',$hubVnet,'-n',$wanSubnetDesiredName,'-o','json') -Json
  $desiredWanPrefixes = Get-SubnetAddressPrefixes -SubnetObj $desiredWanSubnet
  if ($desiredWanPrefixes -notcontains $wanSubnetDesiredPrefix) {
    throw "WAN subnet $wanSubnetDesiredName exists but prefix mismatch. Expected=$wanSubnetDesiredPrefix Actual=$($desiredWanPrefixes -join ',')"
  }
} catch {
  # ignore if missing; fail only on prefix mismatch
  if ($_.Exception.Message -like '*prefix mismatch*') { throw }
}

# WAN: prefer NIC-attached subnet; else prefer any subnet already using desired prefix; else create desired
$wanSubnetFromNic = Get-SubnetInfoFromNic -NicName $wanNic
if ($null -ne $wanSubnetFromNic) {
  if ($wanSubnetFromNic.Prefix -ne $wanSubnetDesiredPrefix) {
    Write-Host "[WARN] WAN NIC $wanNic already attached to subnet $($wanSubnetFromNic.Name) with prefix $($wanSubnetFromNic.Prefix); overriding desired prefix." -ForegroundColor Yellow
  }
  $wanSubnetName = $wanSubnetFromNic.Name
  $wanSubnetPrefix = $wanSubnetFromNic.Prefix
} else {
  $wanSubnetName = $wanSubnetDesiredName
  $wanSubnetPrefix = $wanSubnetDesiredPrefix
  $null = Ensure-SubnetExact -ResourceGroup $rg -VnetName $hubVnet -SubnetName $wanSubnetName -Prefix $wanSubnetPrefix
}
Ensure-SubnetReady -SubnetName $wanSubnetName -Prefix $wanSubnetPrefix
# Allow for ARM propagation before NIC creation
for ($i=1; $i -le 3; $i++) {
  try {
    $checkWan = Invoke-AzCli -Args @('network','vnet','subnet','show','-g',$rg,'--vnet-name',$hubVnet,'-n',$wanSubnetName,'-o','json') -Json
    $wanPrefixes = Get-SubnetAddressPrefixes -SubnetObj $checkWan
    if ($wanPrefixes -contains $wanSubnetPrefix) { break }
    throw "prefix mismatch"
  } catch {
    if ($i -eq 3) { throw "WAN subnet $wanSubnetName (prefix $wanSubnetPrefix) not ready after retries. Last error: $($_.Exception.Message)" }
    Write-Host "[WARN] WAN subnet not ready yet (attempt $i/3); retrying..." -ForegroundColor Yellow
    Start-Sleep -Seconds 5
  }
}

# LAN: prefer NIC-attached subnet; else desired name if exists; else reuse exact start prefix if present; else pick next available /24
$lanSubnetFromNic = Get-SubnetInfoFromNic -NicName $lanNic
if ($null -ne $lanSubnetFromNic) {
  $lanSubnetUsedName = $lanSubnetFromNic.Name
  $lanSubnetPrefix = $lanSubnetFromNic.Prefix
  if ($lanSubnetPrefix -ne $lanStart) {
    Write-Host "[WARN] LAN NIC $lanNic already attached to subnet $lanSubnetUsedName with prefix $lanSubnetPrefix; reusing existing subnet/prefix instead of switching." -ForegroundColor Yellow
    # Use the existing prefix and subnet to avoid conflicts with active allocations.
  }
} else {
  $existingLanByName = $null
  try {
    $existingLanByName = Invoke-AzCli -Args @('network','vnet','subnet','show','-g',$rg,'--vnet-name',$hubVnet,'-n',$lanSubnetName,'-o','json') -Json
  } catch { $existingLanByName = $null }

  if ($null -ne $existingLanByName) {
    $lanSubnetUsedName = $lanSubnetName
    $lanPrefixes = Get-SubnetAddressPrefixes -SubnetObj $existingLanByName
    $lanSubnetPrefix = ($lanPrefixes | Select-Object -First 1)
    if ([string]::IsNullOrWhiteSpace($lanSubnetPrefix)) { throw "LAN subnet $lanSubnetName exists but prefix is empty" }
  } else {
    $startPrefixSubnet = Find-SubnetByPrefix -Subnets $existingSubnets -Prefix $lanStart
    if ($null -ne $startPrefixSubnet) {
      $lanSubnetUsedName = $startPrefixSubnet.Name
      $lanSubnetPrefix = $lanStart
    } else {
      $lanSubnetUsedName = $lanSubnetName
      $lanSubnetPrefix = Get-NextAvailable24 -ExistingSubnets $existingSubnets -StartCidr $lanStart -MaxThirdOctet $lanMax
      $null = Ensure-SubnetExact -ResourceGroup $rg -VnetName $hubVnet -SubnetName $lanSubnetUsedName -Prefix $lanSubnetPrefix
    }
  }
}
$lanEnsureDone = $false
try {
  Ensure-SubnetReady -SubnetName $lanSubnetUsedName -Prefix $lanSubnetPrefix -AllowPrefixMismatch
  $lanEnsureDone = $true
} catch {
  Write-Host ("[WARN] Ensure-SubnetReady failed for {0}/{1}: {2}. Will reuse existing subnet if present instead of changing prefix." -f $lanSubnetUsedName, $lanSubnetPrefix, $_.Exception.Message) -ForegroundColor Yellow
  try {
    $existingLanByName = Invoke-AzCli -Args @('network','vnet','subnet','show','-g',$rg,'--vnet-name',$hubVnet,'-n',$lanSubnetUsedName,'-o','json') -Json
    if ($null -ne $existingLanByName) {
      $lanPrefixes = Get-SubnetAddressPrefixes -SubnetObj $existingLanByName
      $lanSubnetPrefix = ($lanPrefixes | Select-Object -First 1)
      Write-Host ("[INFO] Reusing existing LAN subnet {0} with prefix {1}" -f $lanSubnetUsedName, $lanSubnetPrefix) -ForegroundColor Cyan
      $lanEnsureDone = $true
    }
  } catch {
    throw
  }
}
# Allow for ARM propagation before NIC creation
for ($i=1; $i -le 3; $i++) {
  try {
    $checkLan = Invoke-AzCli -Args @('network','vnet','subnet','show','-g',$rg,'--vnet-name',$hubVnet,'-n',$lanSubnetUsedName,'-o','json') -Json
    $lanPrefixes = Get-SubnetAddressPrefixes -SubnetObj $checkLan
    if ($lanPrefixes -contains $lanSubnetPrefix) { break }
    throw "prefix mismatch"
  } catch {
    if ($i -eq 3) { throw "LAN subnet $lanSubnetUsedName (prefix $lanSubnetPrefix) not ready after retries. Last error: $($_.Exception.Message)" }
    Write-Host "[WARN] LAN subnet not ready yet (attempt $i/3); retrying..." -ForegroundColor Yellow
    Start-Sleep -Seconds 5
  }
}

function Select-FgtLanIp {
  param(
    [Parameter(Mandatory)] [string] $SubnetCidr,
    [Parameter(Mandatory)] [string] $DesiredIp
  )
  if (-not [string]::IsNullOrWhiteSpace($DesiredIp) -and (Test-IpInCidr -Ip $DesiredIp -Cidr $SubnetCidr)) {
    return $DesiredIp
  }
  return (Get-IpAtOffsetInCidr -Cidr $SubnetCidr -HostOffset 4)
}

$fgtLanIpTarget = Select-FgtLanIp -SubnetCidr $lanSubnetPrefix -DesiredIp $desiredLanIp

Write-Host "[STAGE1] Public IP + DNS label" -ForegroundColor Cyan
try {
  Invoke-AzCli -Args @('network','public-ip','show','-g',$rg,'-n',$pipName,'-o','none') | Out-Null
} catch {
  Invoke-AzCli -Args @('network','public-ip','create','-g',$rg,'-n',$pipName,'-l',$location,'--sku','Standard','--allocation-method','Static','--version','IPv4','-o','none') | Out-Null
}
try {
  Invoke-AzCli -Args @('network','public-ip','update','-g',$rg,'-n',$pipName,'--dns-name',$dnsLabel,'-o','none') | Out-Null
} catch {
  $runId = Get-EnvOrDefault -Name 'GITHUB_RUN_ID' -Default 'local'
  $alt = ("{0}-{1}" -f $dnsLabel, $runId).ToLower().Replace('_','').Replace('.','-')
  if ($alt.Length -gt 63) { $alt = $alt.Substring(0,63) }
  Write-Host "[WARN] DNS label '$dnsLabel' failed; trying '$alt'" -ForegroundColor Yellow
  Invoke-AzCli -Args @('network','public-ip','update','-g',$rg,'-n',$pipName,'--dns-name',$alt,'-o','none') | Out-Null
  $dnsLabel = $alt
}

Write-Host "[STAGE1] NSGs" -ForegroundColor Cyan
Ensure-Nsg -ResourceGroup $rg -Name $wanNsg -Location $location
Ensure-NsgRule -ResourceGroup $rg -NsgName $wanNsg -RuleName 'Allow-HTTPS-In' -Priority 100 -Direction Inbound -Access Allow -Protocol 'Tcp' -Source $myCidr -DestPorts '443'
if ($lab.validation.enableSshRule -eq $true) {
  Ensure-NsgRule -ResourceGroup $rg -NsgName $wanNsg -RuleName 'Allow-SSH-In' -Priority 110 -Direction Inbound -Access Allow -Protocol 'Tcp' -Source $myCidr -DestPorts '22'
}
if ($lab.validation.enableIcmpRule -eq $true) {
  Ensure-NsgRule -ResourceGroup $rg -NsgName $wanNsg -RuleName 'Allow-ICMP-In' -Priority 120 -Direction Inbound -Access Allow -Protocol 'Icmp' -Source $myCidr -DestPorts '*'
}
Set-SubnetNsg -ResourceGroup $rg -VnetName $hubVnet -SubnetName $wanSubnetName -NsgName $wanNsg

Ensure-Nsg -ResourceGroup $rg -Name $lanNsg -Location $location
Ensure-NsgRule -ResourceGroup $rg -NsgName $lanNsg -RuleName 'Allow-VNet-In' -Priority 100 -Direction Inbound -Access Allow -Protocol '*' -Source 'VirtualNetwork' -DestPorts '*'
Ensure-NsgRule -ResourceGroup $rg -NsgName $lanNsg -RuleName 'Allow-FGT-LAN-In' -Priority 110 -Direction Inbound -Access Allow -Protocol '*' -Source $fgtLanIpTarget -DestPorts '*'
Ensure-NsgRule -ResourceGroup $rg -NsgName $lanNsg -RuleName 'Deny-Internet-In' -Priority 400 -Direction Inbound -Access Deny -Protocol '*' -Source 'Internet' -DestPorts '*'
Set-SubnetNsg -ResourceGroup $rg -VnetName $hubVnet -SubnetName $lanSubnetUsedName -NsgName $lanNsg

Write-Host "[STAGE1] FortiGate NICs (ensure IP forwarding, attach PIP)" -ForegroundColor Cyan
try {
  Invoke-AzCli -Args @('network','nic','show','-g',$rg,'-n',$wanNic,'-o','none') | Out-Null
} catch {
  Ensure-SubnetReady -SubnetName $wanSubnetName -Prefix $wanSubnetPrefix
  Invoke-AzCli -Args @('network','nic','create','-g',$rg,'-n',$wanNic,'-l',$location,'--vnet-name',$hubVnet,'--subnet',$wanSubnetName,'--public-ip-address',$pipName,'--ip-forwarding','true','-o','none') | Out-Null
}
Invoke-AzCli -Args @('network','nic','update','-g',$rg,'-n',$wanNic,'--ip-forwarding','true','-o','none') | Out-Null
$wanIpCfg = Invoke-AzCli -Args @('network','nic','show','-g',$rg,'-n',$wanNic,'--query','ipConfigurations[0].name','-o','tsv')
Invoke-AzCli -Args @('network','nic','ip-config','update','-g',$rg,'--nic-name',$wanNic,'-n',$wanIpCfg,'--public-ip-address',$pipName,'--vnet-name',$hubVnet,'--subnet',$wanSubnetName,'-o','none') | Out-Null

try {
  Invoke-AzCli -Args @('network','nic','show','-g',$rg,'-n',$lanNic,'-o','none') | Out-Null
} catch {
  Ensure-SubnetReady -SubnetName $lanSubnetUsedName -Prefix $lanSubnetPrefix
  Invoke-AzCli -Args @('network','nic','create','-g',$rg,'-n',$lanNic,'-l',$location,'--vnet-name',$hubVnet,'--subnet',$lanSubnetUsedName,'--private-ip-address',$fgtLanIpTarget,'--ip-forwarding','true','-o','none') | Out-Null
}
Invoke-AzCli -Args @('network','nic','update','-g',$rg,'-n',$lanNic,'--ip-forwarding','true','-o','none') | Out-Null
$lanIpCfg = Invoke-AzCli -Args @('network','nic','show','-g',$rg,'-n',$lanNic,'--query','ipConfigurations[0].name','-o','tsv')
Invoke-AzCli -Args @('network','nic','ip-config','update','-g',$rg,'--nic-name',$lanNic,'-n',$lanIpCfg,'--private-ip-address',$fgtLanIpTarget,'--vnet-name',$hubVnet,'--subnet',$lanSubnetUsedName,'-o','none') | Out-Null

$fgtLanIp = Invoke-AzCli -Args @('network','nic','show','-g',$rg,'-n',$lanNic,'--query','ipConfigurations[0].privateIpAddress','-o','tsv')
if ([string]::IsNullOrWhiteSpace($fgtLanIp)) {
  Write-Host "[WARN] FortiGate LAN IP not yet populated; retrying NIC read (ipconfig=$lanIpCfg, subnet=$lanSubnetUsedName)..." -ForegroundColor Yellow
  Start-Sleep -Seconds 5
  $fgtLanIp = Invoke-AzCli -Args @('network','nic','show','-g',$rg,'-n',$lanNic,'--query','ipConfigurations[0].privateIpAddress','-o','tsv')
}
if ([string]::IsNullOrWhiteSpace($fgtLanIp)) {
  Write-Host "[WARN] FortiGate LAN IP still empty; forcing IP assignment on NIC $lanNic..." -ForegroundColor Yellow
  # Explicitly set subnet ID and static allocation to avoid empty IPs
  $subId = Invoke-AzCli -Args @('account','show','--query','id','-o','tsv')
  $lanSubnetId = "/subscriptions/$subId/resourceGroups/$rg/providers/Microsoft.Network/virtualNetworks/$hubVnet/subnets/$lanSubnetUsedName"
  Invoke-AzCli -Args @(
    'network','nic','update',
    '-g',$rg,
    '-n',$lanNic,
    '--set',"ipConfigurations[0].subnet.id=$lanSubnetId",
           "ipConfigurations[0].privateIpAllocationMethod=Static",
           "ipConfigurations[0].privateIpAddress=$fgtLanIpTarget"
  ) | Out-Null
  Start-Sleep -Seconds 5
  $fgtLanIp = Invoke-AzCli -Args @('network','nic','show','-g',$rg,'-n',$lanNic,'--query','ipConfigurations[0].privateIpAddress','-o','tsv')
}
if ([string]::IsNullOrWhiteSpace($fgtLanIp)) {
  Write-Host "[WARN] FortiGate LAN IP still empty after force-assign; proceeding with target IP $fgtLanIpTarget" -ForegroundColor Yellow
  $fgtLanIp = $fgtLanIpTarget
}

if ($fgtLanIp -ne $fgtLanIpTarget) {
  Write-Host "[WARN] FortiGate LAN IP in use: $fgtLanIp (target was $fgtLanIpTarget, subnet is $lanSubnetPrefix)" -ForegroundColor Yellow
  Ensure-NsgRule -ResourceGroup $rg -NsgName $lanNsg -RuleName 'Allow-FGT-LAN-In' -Priority 110 -Direction Inbound -Access Allow -Protocol '*' -Source $fgtLanIp -DestPorts '*'
} else {
  if ([string]::IsNullOrWhiteSpace($fgtLanIp)) {
    throw "FortiGate LAN IP could not be determined from NIC $lanNic (subnet $lanSubnetUsedName). Check NIC/subnet creation."
  }
  Ensure-NsgRule -ResourceGroup $rg -NsgName $lanNsg -RuleName 'Allow-FGT-LAN-In' -Priority 110 -Direction Inbound -Access Allow -Protocol '*' -Source $fgtLanIp -DestPorts '*'
}

Write-Host "[STAGE1] FortiGate VM (do not recreate if exists)" -ForegroundColor Cyan
$vmExists = $true
try { Invoke-AzCli -Args @('vm','show','-g',$rg,'-n',$fgtVm,'-o','none') | Out-Null } catch { $vmExists = $false }

$bootstrapPath = Join-Path $outDir 'stage1.fgt-bootstrap.conf'
$adminUser = $secret.fgtAdminUsername
$adminPass = $secret.fgtAdminPassword
if ([string]::IsNullOrWhiteSpace($adminUser)) { $adminUser = 'admin' }
if ([string]::IsNullOrWhiteSpace($adminPass)) { $adminPass = 'FortiGate@12345' }

@"
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

config firewall address
    edit "spoke-subnet"
        set subnet $spokeSubnetPrefix
    next
end

config firewall policy
    edit 1
        set name "LAN-to-WAN"
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
"@ | Set-Content -LiteralPath $bootstrapPath -Encoding ASCII

if (-not $vmExists) {
  Invoke-AzCli -Args @('vm','image','terms','accept','--urn',$imageUrn,'-o','none') | Out-Null
  Invoke-AzCli -Args @(
    'vm','create',
    '-g',$rg,'-n',$fgtVm,'-l',$location,
    '--nics',$wanNic,$lanNic,
    '--image',$imageUrn,
    '--size','Standard_F4s_v2',
    '--admin-username',$adminUser,
    '--admin-password',$adminPass,
    '--plan-publisher',$planPublisher,
    '--plan-product',$planProduct,
    '--plan-name',$planName,
    '--custom-data',$bootstrapPath,
    '--os-disk-size-gb','60',
    '--storage-sku','StandardSSD_LRS',
    '-o','none'
  ) | Out-Null
}

$pip = Invoke-AzCli -Args @('network','public-ip','show','-g',$rg,'-n',$pipName,'-o','json') -Json
$fgtFqdn = $pip.dnsSettings.fqdn
$fgtPublicIp = $pip.ipAddress

$outputs = [pscustomobject]@{
  stage = "stage1"
  location = $location
  resourceGroup = $rg
  hubVnet = [pscustomobject]@{
    name = $hubVnet
    id = (Invoke-AzCli -Args @('network','vnet','show','-g',$rg,'-n',$hubVnet,'--query','id','-o','tsv'))
    wanSubnet = [pscustomobject]@{ name = $wanSubnetName; prefix = $wanSubnetPrefix }
    lanSubnet = [pscustomobject]@{ name = $lanSubnetUsedName; prefix = $lanSubnetPrefix }
  }
  fortigate = [pscustomobject]@{
    vmName = $fgtVm
    pipName = $pipName
    publicIp = $fgtPublicIp
    fqdn = $fgtFqdn
    dnsLabel = $dnsLabel
    wanNic = $wanNic
    lanNic = $lanNic
    lanIp = $fgtLanIp
    imageUrn = $imageUrn
    plan = [pscustomobject]@{ publisher = $planPublisher; product = $planProduct; name = $planName }
    bootstrapFile = $bootstrapPath
  }
  nsg = [pscustomobject]@{
    wan = $wanNsg
    lan = $lanNsg
  }
}

Write-JsonFile -Path (Join-Path $outDir 'stage1.outputs.json') -Object $outputs

Write-Host ""
Write-Host "FGT Public IP: $fgtPublicIp"
Write-Host "FGT FQDN:      $fgtFqdn"
Write-Host "GUI URL:       https://$fgtFqdn"
Write-Host "Admin User:    $adminUser"
