Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot/../tools/common.ps1"

$repoRoot = Get-RepoRoot
$configPath = Join-Path $repoRoot 'config/lab.json'
$outDir = Join-Path $repoRoot 'out'
Ensure-Directory -Path $outDir

Test-AzLogin

$lab = Read-JsonFile -Path $configPath
$myCidr = Get-EnvOrDefault -Name 'MY_PUBLIC_IP_CIDR' -Default '0.0.0.0/0'

$stage1 = Read-JsonFile -Path (Join-Path $outDir 'stage1.outputs.json')

$location = $lab.location
$rg = $lab.resourceGroup

$hubVnet = $lab.hub.vnetName
$spokeVnet = $lab.spoke.vnetName
$spokeCidr = $lab.spoke.addressSpace
$spokeSubnetName = $lab.spoke.subnet.name
$spokeSubnetPrefix = $lab.spoke.subnet.prefix

$spokeVmName = $lab.spoke.vm.name
$spokeNicName = $lab.spoke.vm.nicName
$spokeVmImage = $lab.spoke.vm.image
$spokeVmSize = $lab.spoke.vm.size
$spokeVmUser = $lab.spoke.vm.adminUsername
$spokeVmPass = $lab.spoke.vm.adminPassword

$routeTableName = $lab.routing.routeTableName
$routeName = $lab.routing.defaultRouteName
$fgtLanIp = $stage1.fortigate.lanIp

Write-Host "[STAGE2] Spoke VNet + subnet" -ForegroundColor Cyan
try {
  Invoke-AzCli -Args @('network','vnet','show','-g',$rg,'-n',$spokeVnet,'-o','none') | Out-Null
} catch {
  Invoke-AzCli -Args @('network','vnet','create','-g',$rg,'-n',$spokeVnet,'-l',$location,'--address-prefixes',$spokeCidr,'--subnet-name',$spokeSubnetName,'--subnet-prefixes',$spokeSubnetPrefix,'-o','none') | Out-Null
}

# Ensure spoke subnet exists with exact prefix (fail if mismatch)
$null = Ensure-SubnetExact -ResourceGroup $rg -VnetName $spokeVnet -SubnetName $spokeSubnetName -Prefix $spokeSubnetPrefix

Write-Host "[STAGE2] Spoke NSG (subnet-level)" -ForegroundColor Cyan
$spokeNsg = "nsg-$($spokeSubnetName)"
Ensure-Nsg -ResourceGroup $rg -Name $spokeNsg -Location $location
Ensure-NsgRule -ResourceGroup $rg -NsgName $spokeNsg -RuleName 'Allow-SSH-VNet' -Priority 100 -Direction Inbound -Access Allow -Protocol 'Tcp' -Source 'VirtualNetwork' -DestPorts '22'
Ensure-NsgRule -ResourceGroup $rg -NsgName $spokeNsg -RuleName 'Allow-ICMP-In' -Priority 110 -Direction Inbound -Access Allow -Protocol 'Icmp' -Source 'VirtualNetwork' -DestPorts '*'
Set-SubnetNsg -ResourceGroup $rg -VnetName $spokeVnet -SubnetName $spokeSubnetName -NsgName $spokeNsg

Write-Host "[STAGE2] Spoke NIC + VM" -ForegroundColor Cyan
try {
  Invoke-AzCli -Args @('network','nic','show','-g',$rg,'-n',$spokeNicName,'-o','none') | Out-Null
} catch {
  Invoke-AzCli -Args @('network','nic','create','-g',$rg,'-n',$spokeNicName,'-l',$location,'--vnet-name',$spokeVnet,'--subnet',$spokeSubnetName,'-o','none') | Out-Null
}

try {
  Invoke-AzCli -Args @('vm','show','-g',$rg,'-n',$spokeVmName,'-o','none') | Out-Null
} catch {
  Invoke-AzCli -Args @(
    'vm','create','-g',$rg,'-n',$spokeVmName,'-l',$location,
    '--nics',$spokeNicName,
    '--image',$spokeVmImage,
    '--size',$spokeVmSize,
    '--admin-username',$spokeVmUser,
    '--admin-password',$spokeVmPass,
    '--authentication-type','password',
    '--public-ip-address','',
    '-o','none'
  ) | Out-Null
}

Write-Host "[STAGE2] Hub<->Spoke peering (forwarded traffic)" -ForegroundColor Cyan
$hubId = Invoke-AzCli -Args @('network','vnet','show','-g',$rg,'-n',$hubVnet,'--query','id','-o','tsv')
$spokeId = Invoke-AzCli -Args @('network','vnet','show','-g',$rg,'-n',$spokeVnet,'--query','id','-o','tsv')

try { Invoke-AzCli -Args @('network','vnet','peering','show','-g',$rg,'--vnet-name',$hubVnet,'-n','hub-to-spoke','-o','none') | Out-Null } catch {
  Invoke-AzCli -Args @('network','vnet','peering','create','-g',$rg,'--vnet-name',$hubVnet,'-n','hub-to-spoke','--remote-vnet',$spokeId,'--allow-vnet-access','--allow-forwarded-traffic','-o','none') | Out-Null
}
try { Invoke-AzCli -Args @('network','vnet','peering','show','-g',$rg,'--vnet-name',$spokeVnet,'-n','spoke-to-hub','-o','none') | Out-Null } catch {
  Invoke-AzCli -Args @('network','vnet','peering','create','-g',$rg,'--vnet-name',$spokeVnet,'-n','spoke-to-hub','--remote-vnet',$hubId,'--allow-vnet-access','--allow-forwarded-traffic','-o','none') | Out-Null
}

Write-Host "[STAGE2] UDR default via FortiGate" -ForegroundColor Cyan
Ensure-RouteTableAndDefaultRoute -ResourceGroup $rg -Name $routeTableName -Location $location -RouteName $routeName -NextHopIp $fgtLanIp
Invoke-AzCli -Args @('network','vnet','subnet','update','-g',$rg,'--vnet-name',$spokeVnet,'-n',$spokeSubnetName,'--route-table',$routeTableName,'-o','none') | Out-Null

$spokeVmIp = Invoke-AzCli -Args @('vm','list-ip-addresses','-g',$rg,'-n',$spokeVmName,'--query','[0].virtualMachine.network.privateIpAddresses[0]','-o','tsv')
$spokeNicId = Invoke-AzCli -Args @('network','nic','show','-g',$rg,'-n',$spokeNicName,'--query','id','-o','tsv')
$rtId = Invoke-AzCli -Args @('network','route-table','show','-g',$rg,'-n',$routeTableName,'--query','id','-o','tsv')

$outputs = [pscustomobject]@{
  stage = "stage2"
  location = $location
  resourceGroup = $rg
  spokeVnet = [pscustomobject]@{
    name = $spokeVnet
    id = $spokeId
    subnet = [pscustomobject]@{ name = $spokeSubnetName; prefix = $spokeSubnetPrefix }
  }
  spokeVm = [pscustomobject]@{
    name = $spokeVmName
    nicName = $spokeNicName
    nicId = $spokeNicId
    privateIp = $spokeVmIp
  }
  routing = [pscustomobject]@{
    routeTableName = $routeTableName
    routeTableId = $rtId
    nextHopIp = $fgtLanIp
  }
  peering = [pscustomobject]@{
    hubToSpoke = 'hub-to-spoke'
    spokeToHub = 'spoke-to-hub'
  }
}

Write-JsonFile -Path (Join-Path $outDir 'stage2.outputs.json') -Object $outputs

Write-Host ""
Write-Host "Spoke VM IP: $spokeVmIp"
Write-Host "Default route next hop: $fgtLanIp"
