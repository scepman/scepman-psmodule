<#
 .Synopsis
  Registers SCEPman CertMaster Azure AD application.

 .Parameter CertMasterBaseURL
  The base URL of the CertMaster Azure Web App

 .Parameter AzureADAppNameForCertMaster
  Name of the Azure AD app registration for SCEPman Certificate Master. Leave empty to use default name 'SCEPman-CertMaster'

 .Example
   # Registers SCEPman CertMaster Azure AD application where the CertMaster Azure Web App's base URL is 'https://scepman-cm.azurewebsites.net'
   Register-SCEPmanCertMaster 'https://scepman-cm.azurewebsites.net'

 .Example
   # Registers SCEPman CertMaster Azure AD application where the CertMaster Azure Web App's base URL is 'https://scepman-cm.azurewebsites.net' with the display name 'SCEPman-CertMasterApp'
   Register-SCEPmanCertMaster 'https://scepman-cm.azurewebsites.net' -AzureADAppNameForCertMaster 'SCEPman-CertMasterApp'
#>
function Register-SCEPmanCertMaster
{
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [ValidateScript({
            # Ensure URL has a protocol prefix, add https:// if missing
            if ($_ -match '^https?://') {
                return $true
            } elseif ($_ -match '^[a-zA-Z0-9][a-zA-Z0-9\.\-]*[a-zA-Z0-9]\.[a-zA-Z]{2,}(:\d+)?(/.*)?$' -or $_ -match '^localhost(:\d+)?(/.*)?$') {
                # Looks like a domain name or localhost without protocol, we'll add https://
                return $true
            } else {
                throw "CertMasterBaseURL must be a valid URL with protocol (http:// or https://) or a valid domain name."
            }
        })]
        [string]$CertMasterBaseURL,
        $AzureADAppNameForCertMaster = 'SCEPman-CertMaster'
      )
      
      # Ensure CertMasterBaseURL has a protocol prefix
      if ($CertMasterBaseURL -notmatch '^https?://') {
        $CertMasterBaseURL = "https://$CertMasterBaseURL"
        Write-Information "Added https:// prefix to CertMasterBaseURL: $CertMasterBaseURL"
      }
      
      Write-Information "Logging in to az"
      $CurrentAccount = AzLogin

      $appregcm = CreateCertMasterAppRegistration -AzureADAppNameForCertMaster $AzureADAppNameForCertMaster -CertMasterBaseURLs @($CertMasterBaseURL)
      if($null -eq $appregcm) {
        Write-Error "We are unable to register the CertMaster app with the URL '$CertMasterBaseURL'"
        throw "We are unable to register the CertMaster app with the URL '$CertMasterBaseURL'"
      } else {
        Write-Information "SCEPman CertMaster app registration completed with id '$($appregcm.appId)' in the tenant '$($CurrentAccount.homeTenantId)'"
      }
}