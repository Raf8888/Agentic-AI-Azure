Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-RepoRoot {
  $here = Split-Path -Parent $PSScriptRoot
  return (Resolve-Path $here).Path
}

function Ensure-Directory {
  param([Parameter(Mandatory)] [string] $Path)
  if (-not (Test-Path -LiteralPath $Path)) {
    New-Item -ItemType Directory -Path $Path | Out-Null
  }
}

function Read-JsonFile {
  param([Parameter(Mandatory)] [string] $Path)
  if (-not (Test-Path -LiteralPath $Path)) {
    throw "Missing file: $Path"
  }
  return (Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json)
}

function Write-JsonFile {
  param(
    [Parameter(Mandatory)] [string] $Path,
    [Parameter(Mandatory)] $Object
  )
  $json = $Object | ConvertTo-Json -Depth 20
  $dir = Split-Path -Parent $Path
  Ensure-Directory -Path $dir
  Set-Content -LiteralPath $Path -Value $json -Encoding UTF8
}

function Get-EnvOrDefault {
  param(
    [Parameter(Mandatory)] [string] $Name,
    [Parameter(Mandatory)] [string] $Default
  )
  $v = [Environment]::GetEnvironmentVariable($Name)
  if ([string]::IsNullOrWhiteSpace($v)) { return $Default }
  return $v
}

function Invoke-AzCli {
  param(
    [Parameter(Mandatory)] [string[]] $Args,
    [int] $Retries = 3,
    [int] $InitialDelaySeconds = 5,
    [switch] $Json
  )
  $attempt = 1
  $delay = $InitialDelaySeconds
  while ($true) {
    try {
      $out = & az @Args 2>&1
      if ($LASTEXITCODE -ne 0) {
        throw ($out | Out-String)
      }
      if ($Json) {
        if ([string]::IsNullOrWhiteSpace($out)) { return $null }
        return ($out | Out-String | ConvertFrom-Json)
      }
      return ($out | Out-String).Trim()
    } catch {
      if ($attempt -ge $Retries) { throw }
      Write-Host "[WARN] az failed (attempt $attempt/$Retries): $($Args -join ' ')" -ForegroundColor Yellow
      Start-Sleep -Seconds $delay
      $attempt++
      $delay = [Math]::Min($delay * 2, 60)
    }
  }
}

function Test-AzLogin {
  Invoke-AzCli -Args @('account','show','--output','none') | Out-Null
}

function Convert-IPv4ToUInt32 {
  param([Parameter(Mandatory)] [string] $Ip)
  $bytes = [System.Net.IPAddress]::Parse($Ip).GetAddressBytes()
  [Array]::Reverse($bytes)
  return [BitConverter]::ToUInt32($bytes, 0)
}

function Convert-CidrToRange {
  param([Parameter(Mandatory)] [string] $Cidr)
  if ([string]::IsNullOrWhiteSpace($Cidr)) {
    throw "Invalid CIDR format: <empty>"
  }
  $Cidr = $Cidr.Trim()
  if (-not ($Cidr -match '^\d{1,3}(\.\d{1,3}){3}/\d{1,2}$')) {
    throw "Invalid CIDR format: $Cidr"
  }
  $parts = $Cidr.Split('/')
  $ip = $parts[0]
  $prefix = [int]$parts[1]
  if ($prefix -lt 0 -or $prefix -gt 32) {
    throw "Invalid prefix length in CIDR: $Cidr"
  }
  try {
    [void][System.Net.IPAddress]::Parse($ip)
  } catch {
    throw "Invalid IP in CIDR: $Cidr"
  }
  $ipInt = Convert-IPv4ToUInt32 -Ip $ip
  $mask = [uint32]0
  if ($prefix -eq 0) {
    $mask = [uint32]0
  } else {
    $mask = [uint32]([uint32]::MaxValue -shl (32 - $prefix))
  }
  $network = [uint32]($ipInt -band $mask)
  $wildcard = [uint32]([uint32]::MaxValue -bxor $mask)
  $broadcast = [uint32]($network + $wildcard)
  [pscustomobject]@{ Start = $network; End = $broadcast; Cidr = $Cidr }
}

function Convert-UInt32ToIPv4 {
  param([Parameter(Mandatory)] [uint32] $Value)
  $bytes = [BitConverter]::GetBytes($Value)
  [Array]::Reverse($bytes)
  return ([System.Net.IPAddress]::new($bytes)).ToString()
}

function Get-SubnetAddressPrefixes {
  param([Parameter(Mandatory)] $SubnetObj)

  $prefixes = @()
  if ($null -eq $SubnetObj) { return @() }

  if ($null -ne $SubnetObj.PSObject.Properties['addressPrefix']) {
    $prefixes += @($SubnetObj.addressPrefix)
  }
  if ($null -ne $SubnetObj.PSObject.Properties['addressPrefixes']) {
    $prefixes += @($SubnetObj.addressPrefixes)
  }

  return @(
    $prefixes |
      Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
      ForEach-Object { $_.ToString().Trim() }
  )
}

function Test-CidrOverlap {
  param(
    [Parameter(Mandatory)] [string] $CidrA,
    [Parameter(Mandatory)] [string] $CidrB
  )
  $a = Convert-CidrToRange -Cidr $CidrA
  $b = Convert-CidrToRange -Cidr $CidrB
  return -not ($a.End -lt $b.Start -or $b.End -lt $a.Start)
}

function Test-IpInCidr {
  param(
    [Parameter(Mandatory)] [string] $Ip,
    [Parameter(Mandatory)] [string] $Cidr
  )
  $r = Convert-CidrToRange -Cidr $Cidr
  $ipInt = Convert-IPv4ToUInt32 -Ip $Ip
  return ($ipInt -ge $r.Start -and $ipInt -le $r.End)
}

function Get-IpAtOffsetInCidr {
  param(
    [Parameter(Mandatory)] [string] $Cidr,
    [Parameter(Mandatory)] [int] $HostOffset
  )
  $r = Convert-CidrToRange -Cidr $Cidr
  $ipInt = [uint32]($r.Start + [uint32]$HostOffset)
  return (Convert-UInt32ToIPv4 -Value $ipInt)
}

function Get-HubSubnets {
  param(
    [Parameter(Mandatory)] [string] $ResourceGroup,
    [Parameter(Mandatory)] [string] $VnetName
  )
  $subnets = Invoke-AzCli -Args @('network','vnet','subnet','list','-g',$ResourceGroup,'--vnet-name',$VnetName,'-o','json') -Json
  return @($subnets | ForEach-Object {
    [pscustomobject]@{
      Name = $_.name
      Prefixes = (Get-SubnetAddressPrefixes -SubnetObj $_)
    }
  })
}

function Find-SubnetByPrefix {
  param(
    [Parameter(Mandatory)] [object[]] $Subnets,
    [Parameter(Mandatory)] [string] $Prefix
  )
  foreach ($s in $Subnets) {
    foreach ($p in $s.Prefixes) {
      if ($p -eq $Prefix) { return $s }
    }
  }
  return $null
}

function Ensure-SubnetExact {
  param(
    [Parameter(Mandatory)] [string] $ResourceGroup,
    [Parameter(Mandatory)] [string] $VnetName,
    [Parameter(Mandatory)] [string] $SubnetName,
    [Parameter(Mandatory)] [string] $Prefix
  )
  $existing = $null
  try {
    $existing = Invoke-AzCli -Args @('network','vnet','subnet','show','-g',$ResourceGroup,'--vnet-name',$VnetName,'-n',$SubnetName,'-o','json') -Json
  } catch { $existing = $null }

  if ($null -ne $existing) {
    $existingPrefixes = Get-SubnetAddressPrefixes -SubnetObj $existing
    if ($existingPrefixes -notcontains $Prefix) {
      throw "Subnet $SubnetName exists but prefix mismatch. Expected=$Prefix Actual=$($existingPrefixes -join ',')"
    }
    return [pscustomobject]@{ Name = $SubnetName; Prefix = $Prefix; Created = $false }
  }

  Invoke-AzCli -Args @('network','vnet','subnet','create','-g',$ResourceGroup,'--vnet-name',$VnetName,'-n',$SubnetName,'--address-prefixes',$Prefix,'-o','none') | Out-Null
  return [pscustomobject]@{ Name = $SubnetName; Prefix = $Prefix; Created = $true }
}

function Get-NextAvailable24 {
  param(
    [Parameter(Mandatory)] [object[]] $ExistingSubnets,
    [Parameter(Mandatory)] [string] $StartCidr,
    [int] $MaxThirdOctet = 250
  )
  # Validate input start CIDR (friendly errors instead of UInt32 conversion failures)
  $null = Convert-CidrToRange -Cidr $StartCidr

  $startIp = $StartCidr.Split('/')[0]
  $octets = $startIp.Split('.')
  $base0 = [int]$octets[0]
  $base1 = [int]$octets[1]
  $thirdStart = [int]$octets[2]

  for ($third = $thirdStart; $third -le $MaxThirdOctet; $third++) {
    $candidate = "$base0.$base1.$third.0/24"
    $overlaps = $false
    foreach ($s in $ExistingSubnets) {
      foreach ($p in $s.Prefixes) {
        if ([string]::IsNullOrWhiteSpace($p)) { continue }
        try {
          if (Test-CidrOverlap -CidrA $candidate -CidrB $p) { $overlaps = $true; break }
        } catch {
          Write-Host "[WARN] Skipping invalid existing subnet CIDR '$p' while selecting LAN /24: $($_.Exception.Message)" -ForegroundColor Yellow
          $overlaps = $true
          break
        }
      }
      if ($overlaps) { break }
    }
    if (-not $overlaps) { return $candidate }
  }
  throw "No available /24 found starting at $StartCidr"
}

function Ensure-Nsg {
  param(
    [Parameter(Mandatory)] [string] $ResourceGroup,
    [Parameter(Mandatory)] [string] $Name,
    [Parameter(Mandatory)] [string] $Location
  )
  try {
    Invoke-AzCli -Args @('network','nsg','show','-g',$ResourceGroup,'-n',$Name,'-o','none') | Out-Null
  } catch {
    Invoke-AzCli -Args @('network','nsg','create','-g',$ResourceGroup,'-n',$Name,'-l',$Location,'-o','none') | Out-Null
  }
}

function Ensure-NsgRule {
  param(
    [Parameter(Mandatory)] [string] $ResourceGroup,
    [Parameter(Mandatory)] [string] $NsgName,
    [Parameter(Mandatory)] [string] $RuleName,
    [Parameter(Mandatory)] [int] $Priority,
    [Parameter(Mandatory)] [string] $Direction,
    [Parameter(Mandatory)] [string] $Access,
    [Parameter(Mandatory)] [string] $Protocol,
    [Parameter(Mandatory)] [string] $Source,
    [Parameter(Mandatory)] [string] $DestPorts
  )
  $baseArgs = @(
    'network','nsg','rule','create',
    '-g',$ResourceGroup,
    '--nsg-name',$NsgName,
    '-n',$RuleName,
    '--priority',"$Priority",
    '--direction',$Direction,
    '--access',$Access,
    '--protocol',$Protocol,
    '--source-address-prefixes',$Source,
    '--source-port-ranges','*',
    '--destination-address-prefixes','*',
    '--destination-port-ranges',$DestPorts,
    '-o','none'
  )
  try {
    Invoke-AzCli -Args @('network','nsg','rule','show','-g',$ResourceGroup,'--nsg-name',$NsgName,'-n',$RuleName,'-o','none') | Out-Null
    $baseArgs[3] = 'update'
    Invoke-AzCli -Args $baseArgs | Out-Null
  } catch {
    Invoke-AzCli -Args $baseArgs | Out-Null
  }
}

function Set-SubnetNsg {
  param(
    [Parameter(Mandatory)] [string] $ResourceGroup,
    [Parameter(Mandatory)] [string] $VnetName,
    [Parameter(Mandatory)] [string] $SubnetName,
    [Parameter(Mandatory)] [string] $NsgName
  )
  Invoke-AzCli -Args @('network','vnet','subnet','update','-g',$ResourceGroup,'--vnet-name',$VnetName,'-n',$SubnetName,'--network-security-group',$NsgName,'-o','none') | Out-Null
}

function Ensure-RouteTableAndDefaultRoute {
  param(
    [Parameter(Mandatory)] [string] $ResourceGroup,
    [Parameter(Mandatory)] [string] $Name,
    [Parameter(Mandatory)] [string] $Location,
    [Parameter(Mandatory)] [string] $RouteName,
    [Parameter(Mandatory)] [string] $NextHopIp
  )
  try {
    Invoke-AzCli -Args @('network','route-table','show','-g',$ResourceGroup,'-n',$Name,'-o','none') | Out-Null
  } catch {
    Invoke-AzCli -Args @('network','route-table','create','-g',$ResourceGroup,'-n',$Name,'-l',$Location,'-o','none') | Out-Null
  }
  try {
    Invoke-AzCli -Args @('network','route-table','route','show','-g',$ResourceGroup,'--route-table-name',$Name,'-n',$RouteName,'-o','none') | Out-Null
    Invoke-AzCli -Args @('network','route-table','route','update','-g',$ResourceGroup,'--route-table-name',$Name,'-n',$RouteName,'--address-prefix','0.0.0.0/0','--next-hop-type','VirtualAppliance','--next-hop-ip-address',$NextHopIp,'-o','none') | Out-Null
  } catch {
    Invoke-AzCli -Args @('network','route-table','route','create','-g',$ResourceGroup,'--route-table-name',$Name,'-n',$RouteName,'--address-prefix','0.0.0.0/0','--next-hop-type','VirtualAppliance','--next-hop-ip-address',$NextHopIp,'-o','none') | Out-Null
  }
}
