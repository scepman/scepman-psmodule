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

      Write-Information "Getting App ID of Certificate Master"
      $CertMasterAppId = ExecuteAzCommandRobustly -azCommand ("az webapp config appsettings list --name $CertMasterAppServiceName --resource-group $CertMasterResourceGroup --query ""[?name=='AppConfig:AuthConfig:HomeApplicationId'].value | [0]"" --output tsv")
      if ([String]::IsNullOrWhiteSpace($CertMasterAppId)) {
        $CertMasterAppId = ExecuteAzCommandRobustly -azCommand ("az webapp config appsettings list --name $CertMasterAppServiceName --resource-group $CertMasterResourceGroup --query ""[?name=='AppConfig:AuthConfig:ApplicationId'].value | [0]"" --output tsv")
        if ([String]::IsNullOrWhiteSpace($CertMasterAppId)) {
          Write-Error "Could not find App ID of Certificate Master"
          throw "Could not find App ID of Certificate Master"
        }
      }
      Write-Verbose "Certificate Master App ID is $CertMasterAppId"

      # Expose CertMaster API
      Write-Information "Making sure that Certificate Master exposes its API"
      ExecuteAzCommandRobustly -azCommand "az ad app update --id $CertMasterAppId --identifier-uris `"api://$CertMasterAppId`""

      # Add az as Client Application to SCEPman-CertMaster
      Write-Information "Making sure that az is authorized to access Certificate Master"
      $AzAuthorizationWasAdded = Add-AzAsTrustedClientApplication -AppId $CertMasterAppId

      # Get Token to log on to Certificate Master
      if ($AzAuthorizationWasAdded) {
        # TODO: Some delay is required here, otherwise we cannot get a token
      }
      $cm_token = $(az account get-access-token --scope api://$CertMasterAppId/.default --query accessToken --output tsv) | ConvertTo-SecureString -AsPlainText -Force

      # TODO: Find CertMaster version and check if it is compatible

      # Some definitions to iterate through the search filters
      function IsEverythingFinished([string]$CurrentSearchFilter, [string]$GlobalSearchFilter) {
        if ('STOP' -eq $CurrentSearchFilter) {
          return $true
        }

        $startOfCurrentSearchFilter = $CurrentSearchFilter.Substring(0, $GlobalSearchFilter.Length)
        if ([Convert]::ToInt32($startOfCurrentSearchFilter, 16) -gt [Convert]::ToInt32($GlobalSearchFilter, 16)) {
          return $true
        }

        return $false
      }

      function NextSearchFilter([string]$CurrentSearchFilter) {
        if ([String]::IsNullOrWhiteSpace($CurrentSearchFilter)) {
          return 'STOP'
        }
        for ([int]$pos = $currentSearchFilter.Length - 1; $pos -ge 0; $pos--) {
          if ($currentSearchFilter[$pos] -eq 'f') {
            $CurrentSearchFilter[$pos] = '0'
          } else {
            $CurrentSearchFilter[$pos] = [char]([int]$CurrentSearchFilter[$pos] + 1)  # TODO: Ensure this is hex
            return $CurrentSearchFilter
        }
        return 'STOP' # The filter is ff...f, so we are done
      }

      Write-Information "Instructing Certificate Master to sync certificates"
      for ($currentSearchFilter = $CertificateSearchString; -not (IsEverythingFinished -currentSearchFilter $currentSearchFilter -GlobalSearchFilter $CertificateSearchFilter); $currentSearchFilter = NextSearchFilter -currentSearchFilter $currentSearchFilter) {
        Write-Information "Syncing certificates with filter '$currentSearchFilter'"
        $result = Invoke-WebRequest -Method Post -Uri "$CertMasterBaseURL/api/migrate-certificates/$currentSearchFilter" -Authentication Bearer -Token $cm_token -UseBasicParsing

        # TODO: Check the status code and print the number of certificates that were synced
      }

      if ($AzAuthorizationWasAdded) { # Only revert if we added the authorization
        Write-Information "Reverting az access to Certificate Master"

        Remove-AsAsTrustedClientApplication -AppId $CertMasterAppId
      }
}