<#
 .Synopsis
  Copies certificate information from the Intune API to SCEPman's Storage Account

#>
function Sync-IntuneCertificates
{
    [CmdletBinding()]
    param(
      $CertMasterAppServiceName,
      $CertMasterResourceGroup,
      [switch]$SearchAllSubscriptions,
      $SubscriptionId,
      $CertificateSearchString
      )

      $version = $MyInvocation.MyCommand.ScriptBlock.Module.Version
      Write-Verbose "Invoked $($MyInvocation.MyCommand)"
      Write-Information "SCEPman Module version $version on PowerShell $($PSVersionTable.PSVersion)"
  
      $cliVersion = [Version]::Parse((GetAzVersion).'azure-cli')
      Write-Information "Detected az version: $cliVersion"

      If ($PSBoundParameters['Debug']) {
          $DebugPreference='Continue' # Do not ask user for confirmation, so that the script can run unattended
      }

      if ([String]::IsNullOrWhiteSpace($CertMasterAppServiceName)) {
          $CertMasterAppServiceName = Read-Host "Please enter the Certificate Master app service name"
      }

      Write-Information "Copying Intune Certificates from Intune API to Certificate Master Storage Account using filter '$CertificateSearchString'"
  
      Write-Information "Logging in to az"
      $null = AzLogin
  
      Write-Information "Getting subscription details"
      $subscription = GetSubscriptionDetails -AppServiceName $CertMasterAppServiceName -SearchAllSubscriptions $SearchAllSubscriptions.IsPresent -SubscriptionId $SubscriptionId
      Write-Information "Subscription is set to $($subscription.name)"

      Write-Information "Setting resource group"
      if ([String]::IsNullOrWhiteSpace($CertMasterResourceGroup)) {
          # No resource group given, search for it now
          $CertMasterResourceGroup = GetResourceGroup -SCEPmanAppServiceName $CertMasterAppServiceName
      }

      Write-Information "Finding API endpoint of Certificate Master"
      $CertMasterHostNames = GetAppServiceHostNames -appServiceName $CertMasterAppServiceName -SCEPmanResourceGroup $CertMasterResourceGroup
      $CertMasterBaseURLs = @($CertMasterHostNames | ForEach-Object { "https://$_" })
      $CertMasterBaseURL = $CertMasterBaseURLs[0]
      Write-Verbose "CertMaster web app url is $CertMasterBaseURL"

      # Expose CertMaster API
      $CertMasterAppId = ExecuteAzCommandRobustly -azCommand ("az webapp config appsettings list --name $CertMasterAppServiceName --resource-group $CertMasterResourceGroup --query ""[?name=='AppConfig:AuthConfig:HomeApplicationId'].value | [0]"" --output tsv")
      if ([String]::IsNullOrWhiteSpace($CertMasterAppId)) {
        $CertMasterAppId = ExecuteAzCommandRobustly -azCommand ("az webapp config appsettings list --name $CertMasterAppServiceName --resource-group $CertMasterResourceGroup --query ""[?name=='AppConfig:AuthConfig:ApplicationId'].value | [0]"" --output tsv")
        if ([String]::IsNullOrWhiteSpace($CertMasterAppId)) {
          Write-Error "Could not find App ID of Certificate Master"
          throw "Could not find App ID of Certificate Master"
        }
      }
      ExecuteAzCommandRobustly -azCommand "az ad app update --id $CertMasterAppId --identifier-uris `"api://$CertMasterAppId`""

      # Get Token to log on to Certificate Master
      $cm_token = $(az account get-access-token --scope api://$CertMasterAppId/.default --query accessToken --output tsv) | ConvertTo-SecureString -AsPlainText -Force

      # TODO: Find CertMaster version and check if it is compatible

      Write-Information "Instructing Certificate Master to sync certificates"
      $currentSearchFilter = $CertificateSearchString
      Invoke-WebRequest -Method Post -Uri "$CertMasterBaseURL/migrate-certificates/$currentSearchFilter" -Authentication Bearer -Token $cm_token -UseBasicParsing


      $migrationResponseLines = ExecuteAzCommandRobustly -azCommand "az rest --method post --uri $CertMasterBaseURL/migrate-certificates/$currentSearchFilter --resource $CertMasterBaseURL"
      $migrationResponse = Convert-LinesToObject -lines $migrationResponseLines

}