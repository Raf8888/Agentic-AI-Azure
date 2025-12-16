param(
  [string]$SubscriptionId = "23e3d7b2-4fbf-4d74-9707-c6ca4d521d42",
  [string]$SpName = "github-fgt-agent"
)

az login
az account set --subscription $SubscriptionId

$sp = az ad sp create-for-rbac `
  --name $SpName `
  --role contributor `
  --scopes "/subscriptions/$SubscriptionId" `
  --sdk-auth

Write-Host ""
Write-Host "==== Paste this JSON into GitHub secret AZURE_CREDENTIALS ===="
Write-Host $sp
