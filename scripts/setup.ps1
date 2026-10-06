<#
.SYNOPSIS
  One-time bootstrap: resource group + Entra app with GitHub OIDC federation (no stored secrets).
.EXAMPLE
  ./scripts/setup.ps1 -GitHubRepo myorg/my-mlops-repo
#>
param(
    [Parameter(Mandatory)][string]$GitHubRepo,   # owner/repo
    [string]$ResourceGroup = "rg-mlops",
    [string]$Location = "westeurope",
    [string]$AppName = "sp-mlops-github"
)
$ErrorActionPreference = "Stop"

$sub = az account show --query id -o tsv
$tenant = az account show --query tenantId -o tsv

az group create --name $ResourceGroup --location $Location -o none
$rgId = az group show --name $ResourceGroup --query id -o tsv

$appId = az ad app create --display-name $AppName --query appId -o tsv
az ad sp create --id $appId -o none
az role assignment create --assignee $appId --role Contributor --scope $rgId -o none

# One federated credential per GitHub context that logs in to Azure.
foreach ($subject in @("ref:refs/heads/main", "environment:production", "pull_request")) {
    $body = @{
        name      = ($subject -replace "[^A-Za-z0-9]", "-")
        issuer    = "https://token.actions.githubusercontent.com"
        subject   = "repo:${GitHubRepo}:$subject"
        audiences = @("api://AzureADTokenExchange")
    } | ConvertTo-Json -Compress
    $file = New-TemporaryFile
    Set-Content -Path $file -Value $body -Encoding utf8
    az ad app federated-credential create --id $appId --parameters "@$file" -o none
    Remove-Item $file
}

Write-Host "`nDone. Add these to GitHub (Settings > Secrets and variables > Actions):`n"
Write-Host "Secrets:   AZURE_CLIENT_ID=$appId  AZURE_TENANT_ID=$tenant  AZURE_SUBSCRIPTION_ID=$sub"
Write-Host "Variables: AZURE_RESOURCE_GROUP=$ResourceGroup  AZURE_ML_WORKSPACE=mlw-mlops  ENDPOINT_NAME=<globally-unique-name>"
Write-Host "Optional:  GATE_MIN_R2=0.3  GATE_MIN_DELTA=0.0  TRAFFIC_STEPS='10 50 100'  BAKE_SECONDS=300"
Write-Host "           ALERT_EMAIL=<you@example.com>  AML_ISOLATION_MODE=AllowInternetOutbound  AML_PRIVATE_ENDPOINTS=false"
Write-Host "           ENDPOINT_PUBLIC_ACCESS=enabled  RUNNER_LABEL=<self-hosted label, required once private endpoints are on>"
Write-Host "Also create a GitHub environment named 'production' (add required reviewers for approval)."
