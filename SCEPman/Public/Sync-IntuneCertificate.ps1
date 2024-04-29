<#
 .Synopsis
  Copies certificate information from the Intune API to SCEPman's Storage Account

#>
function Sync-IntuneCertificate
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
    $CertMasterAppId = ReadAppSetting -ResourceGroup $CertMasterResourceGroup -AppServiceName $CertMasterAppServiceName -SettingName "AppConfig:AuthConfig:HomeApplicationId"
    if ([String]::IsNullOrWhiteSpace($CertMasterAppId)) {
      $CertMasterAppId = ReadAppSetting -ResourceGroup $CertMasterResourceGroup -AppServiceName $CertMasterAppServiceName -SettingName "AppConfig:AuthConfig:ApplicationId"
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
      Write-Information "Waiting five seconds for az authorization to be effective"
      Start-Sleep -Seconds 5
    }

    Write-Information "Getting access token for Certificate Master"
    $cm_token = Get-AccessTokenForApp -Scope "api://$CertMasterAppId/.default"

    try {

      # TODO: Find CertMaster version and check if it is compatible

      # Some definitions to iterate through the search filters
      function IsEverythingFinished([string]$CurrentSearchFilter, [string]$GlobalSearchFilter) {
        Write-Debug "IsEverythingFinished: CurrentSearchFilter=$CurrentSearchFilter, GlobalSearchFilter=$GlobalSearchFilter"
        if ('STOP' -eq $CurrentSearchFilter) {
          return $true
        }

        if ([String]::IsNullOrWhiteSpace($GlobalSearchFilter)) {  # If the global search filter is empty, the CurrentSearchFilter must be set to STOP explictly
          return $false
        }

        $startOfCurrentSearchFilter = $CurrentSearchFilter.Substring(0, $GlobalSearchFilter.Length)
        if ([Convert]::ToInt32($startOfCurrentSearchFilter, 16) -gt [Convert]::ToInt32($GlobalSearchFilter, 16)) {
          return $true
        }

        return $false
      }

      function NextSearchFilter([string]$CurrentSearchFilter, [bool]$ProgressCondition) {
        if (-not $ProgressCondition) {
          return $CurrentSearchFilter
        }

        if ([String]::IsNullOrWhiteSpace($CurrentSearchFilter)) {
          return 'STOP'
        }

        if ($CurrentSearchFilter.EndsWith('x')) {  # The special code for "retry with more narrow search filter"
          $CurrentSearchFilter = $CurrentSearchFilter.Substring(0, $CurrentSearchFilter.Length - 1) # Remove the 'x'
          return $CurrentSearchFilter + '0'  # Retry with more narrow search filter
        } else {
          for ([int]$pos = $currentSearchFilter.Length - 1; $pos -ge 0; $pos--) {
            if ($currentSearchFilter[$pos] -eq 'f') {
              $CurrentSearchFilter = $CurrentSearchFilter.Substring(0, $pos) + '0' + $CurrentSearchFilter.Substring($pos + 1)
            } else {
              $currentDigitValue = [Convert]::ToInt32($CurrentSearchFilter[$pos].ToString(),16)
              $nextChar = [Convert]::ToString($currentDigitValue + 1, 16)  # Increment the hex number at the position
              $CurrentSearchFilter = $CurrentSearchFilter.Substring(0, $pos) + $nextChar + $CurrentSearchFilter.Substring($pos + 1)
              return $CurrentSearchFilter}
          }
          return 'STOP' # The filter is ff...f, so we are done
        }
      }

      function GetStartFilter([string]$GlobalSearchFilter) {
        if ([String]::IsNullOrWhiteSpace($GlobalSearchFilter)) {
          return '0'
        }

        return $GlobalSearchFilter
      }

      Write-Information "Instructing Certificate Master to sync certificates"
      $totalSuccessCount = 0
      $totalSkippedCount = 0
      $totalFailedCount = 0
      $retryAuthorization = $true
      for (
        $currentSearchFilter = GetStartFilter($CertificateSearchString);
        -not (IsEverythingFinished -currentSearchFilter $currentSearchFilter -GlobalSearchFilter $CertificateSearchString);
        $currentSearchFilter = NextSearchFilter -currentSearchFilter $currentSearchFilter -ProgressCondition $retryAuthorization
      ) {
        Write-Verbose "Syncing certificates with filter '$currentSearchFilter'"

        # Invoke-RestMethod is not possible, since we would lose access to the StatusCode. Therefore we must parse the JSON manually.
        $result = Invoke-WebRequest -Method Post -Uri "$CertMasterBaseURL/api/maintenance/migrate-certificates/$currentSearchFilter" -Authentication Bearer -Token $cm_token -UseBasicParsing -SkipHttpErrorCheck

        switch ($result.StatusCode) {
          201 { # Created
            $jsonContent = $result.Content | ConvertFrom-Json
            Write-Information "Successfully synced $($jsonContent.SuccessfulCertificates) certificates with filter '$currentSearchFilter'; $($jsonContent.SkippedCertificates) were skipped; There were $($jsonContent.FailedCertificates) certificate failures"
            $totalSuccessCount += $jsonContent.SuccessfulCertificates
            $totalSkippedCount += $jsonContent.SkippedCertificates
            $totalFailedCount += $jsonContent.FailedCertificates
            $retryAuthorization = $true
          }
          401 { # Unauthorized
            if ($retryAuthorization) {
              Write-Warning "Unauthorized to sync certificates with filter '$currentSearchFilter'. Retrying with new token..."
              $cm_token = Get-AccessTokenForApp -Scope "api://$CertMasterAppId/.default"
              $retryAuthorization = $false
            } else {
              Write-Error "Unauthorized to sync certificates with filter '$currentSearchFilter'"
              throw "Unauthorized to sync certificates with filter '$currentSearchFilter'"
            }
          }
          504 { # Gateway Timeout
            $jsonContent = $result.Content | ConvertFrom-Json
            Write-Information "Gateway Timeout while syncing certificates with filter '$currentSearchFilter'. Before this, $($jsonContent.SuccessfulCertificates) certificates were synched and $($jsonContent.SkippedCertificates) were skipped, while $($jsonContent.FailedCertificates) certificates failed. Retrying with more narrow search filter..."
            $totalSuccessCount += $jsonContent.SuccessfulCertificates
            $totalSkippedCount += $jsonContent.SkippedCertificates
            $totalFailedCount += $jsonContent.FailedCertificates
            $currentSearchFilter += 'x' # The special code for "retry with more narrow search filter"
            if ($currentSearchFilter.Length -gt 8) {
              Write-Error "The search filter is already very narrow, but still the gateway timed out. Giving up."
              throw "The search filter is already very narrow, but still the gateway timed out. Giving up."
            }
            $retryAuthorization = $true
          }
          default {
            Write-Error "Failed to sync certificates with filter '$currentSearchFilter' with status code $($result.StatusCode) and content [$($result.Content)]"
            throw "Failed to sync certificates with filter '$currentSearchFilter'"
          }
        }
      }

      Write-Information "Syncing certificates finished. Total: $totalSuccessCount certificates were synched, $totalSkippedCount were skipped (possibly multiple times if there have been Gateway Timeouts), and $totalFailedCount failed"
    }
    finally {
      if ($AzAuthorizationWasAdded) { # Only revert if we added the authorization
        Write-Information "Reverting az access to Certificate Master"

        Remove-AsAsTrustedClientApplication -AppId $CertMasterAppId
      }
    }
}