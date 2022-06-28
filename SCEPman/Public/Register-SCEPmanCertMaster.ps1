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
        [Parameter(Mandatory=$true)]$CertMasterBaseURL,
        $AzureADAppNameForCertMaster = 'SCEPman-CertMaster'
      )
      $appregcm = CreateCertMasterAppRegistration -AzureADAppNameForCertMaster $AzureADAppNameForCertMaster -CertMasterBaseURL $CertMasterBaseURL
      if($null -eq $appregcm) {
        Write-Error "We are unable to register the CertMaster app with the URL '$CertMasterBaseURL'"
        throw "We are unable to register the CertMaster app with the URL '$CertMasterBaseURL'"
      } else {
        $CurrentAccount = GetCurrentAccount
        Write-Information "SCEPman CertMaster app registration completed with id '$($appregcm.appId)' in the tenant '$($CurrentAccount.homeTenantId)'"
      }
}