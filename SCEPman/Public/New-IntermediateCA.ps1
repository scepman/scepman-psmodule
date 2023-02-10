<#
 .Synopsis
  Creates a Certificate Signing Request (CSR) for an Intermediate CA Certificate that SCEPman shall use

 .Parameter SCEPmanAppServiceName
  The name of the existing SCEPman App Service.

 .Parameter SCEPmanResourceGroup
  The Azure resource group hosting the SCEPman App Service. Leave empty for auto-detection.

 .Parameter SearchAllSubscriptions
  Set this flag to search all subscriptions for the SCEPman App Service. Otherwise, pre-select the right subscription in az or pass in the correct SubscriptionId.

 .Parameter SubscriptionId
  The ID of the Subscription where SCEPman is installed. Can be omitted if it is pre-selected in az already or use the SearchAllSubscriptions flag to search all accessible subscriptions

 .PARAMETER GraphBaseUri
  URI of Microsoft Graph. This is https://graph.microsoft.com/ for the global cloud (default) and https://graph.microsoft.us/ for the GCC High cloud.

 .Example
   # Configure SCEPman in your tenant where the app service name is as-scepman
   $csr = New-IntermediateCA -SCEPmanAppServiceName as-scepman

   #>
function New-IntermediateCA
{
  [CmdletBinding()]
  param(
      $SCEPmanAppServiceName,
      $SCEPmanResourceGroup,
      [switch]$SearchAllSubscriptions,
      $SubscriptionId,
      $GraphBaseUri = 'https://graph.microsoft.com'
      )

  $version = $MyInvocation.MyCommand.ScriptBlock.Module.Version
  Write-Verbose "Invoked $($MyInvocation.MyCommand)"
  Write-Information "SCEPman Module version $version on PowerShell $($PSVersionTable.PSVersion)"

  $cliVersion = [Version]::Parse((GetAzVersion).'azure-cli')
  Write-Information "Detected az version: $cliVersion"

  if ([String]::IsNullOrWhiteSpace($SCEPmanAppServiceName)) {
    $SCEPmanAppServiceName = Read-Host "Please enter the SCEPman app service name"
  }

  $GraphBaseUri = $GraphBaseUri.TrimEnd('/')

  Write-Information "Configuring SCEPman and CertMaster"

  Write-Information "Logging in to az"
  $null = AzLogin

  Write-Information "Getting subscription details"
  $subscription = GetSubscriptionDetails -AppServiceName $SCEPmanAppServiceName -SearchAllSubscriptions $SearchAllSubscriptions.IsPresent -SubscriptionId $SubscriptionId
  Write-Information "Subscription is set to $($subscription.name)"

  Write-Information "Setting resource group"
  if ([String]::IsNullOrWhiteSpace($SCEPmanResourceGroup)) {
      # No resource group given, search for it now
      $SCEPmanResourceGroup = GetResourceGroup -SCEPmanAppServiceName $SCEPmanAppServiceName
  }


  $vaultUrl = FindConfiguredKeyVaultUrl -SCEPmanAppServiceName $SCEPmanAppServiceName -SCEPmanResourceGroup $SCEPmanResourceGroup

  $certificateName = az webapp config appsettings list --name $SCEPmanAppServiceName --resource-group $SCEPmanResourceGroup --query "[?name=='AppConfig:KeyVaultConfig:RootCertificateConfig:CertificateName'].value | [0]" --output tsv
  Write-Information "Found Key Vault configuration with URL $vaultUrl and certificate name $certificateName. Creating certificate request in Key Vault ..."
  
  $csr = New-IntermediateCaCsr -vaultUrl $vaultUrl -certificateName $certificateName

  Write-Information "Created a CSR. Submit the CSR to a CA and merge the signed certificate in the Azure Portal"
  Write-Output $csr
}

function Get-IntermediateCaPolicy {
 
  return $global:subCaPolicy
}

function Set-IntermediateCaPolicy () {
  [CmdletBinding()]
  param(
      $Policy
  )

  $global:subCaPolicy = $Policy
}

function Reset-IntermediateCaPolicy () {

  $global:subCaPolicy = $global:rsaPolicyTemplate
}