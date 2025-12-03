<#
 .Synopsis
  Adds permission for an existing service principal (Enterprise Application or Managed Identity) to submit CSR requests to SCEPman's REST API.

 .Parameter ServicePrincipalId
  Your Enterprise Application or Managed Identity's object ID. This entity will be granted permission to submit CSR requests to SCEPman's REST API.

 .Parameter AzureADAppNameForSCEPman
  Name of the Azure AD app registration for SCEPman (default is scepman-api)

 .Parameter Role
  The specific role to assign to the service principal. This is CSR.Request.Db by default. It is not recommended to use a different role.

 .PARAMETER GraphBaseUri
  URI of Microsoft Graph. This is https://graph.microsoft.com/ for the global cloud (default) and https://graph.microsoft.us/ for the GCC High cloud.

 .Example
   # Allow your Enterprise Application with Object ID 00000000-0000-0000-0000-000000000000 to submit CSR requests to SCEPman's REST API
   Register-SCEPmanApiClient -ServicePrincipalId 00000000-0000-0000-0000-000000000000 6>&1

#>
function Register-SCEPmanApiClient
{
  [CmdletBinding()]
  param(
    [Parameter(Mandatory=$true)]$ServicePrincipalId,
    $AzureADAppNameForSCEPman = 'SCEPman-api',
    $Role = 'CSR.Request.Db',
    $GraphBaseUri = 'https://graph.microsoft.com'
    )

  if(-not $PSBoundParameters.ContainsKey('InformationAction')) {
    Write-Debug "Setting InformationAction to 'Continue' for this cmdlet as no user preference was set."
    $InformationPreference = 'Continue'
  }

  $version = $MyInvocation.MyCommand.ScriptBlock.Module.Version
  Write-Verbose "Invoked $($MyInvocation.MyCommand)"
  Write-Information "SCEPman Module version $version on PowerShell $($PSVersionTable.PSVersion)"

  $cliVersion = [Version]::Parse((GetAzVersion).'azure-cli')
  Write-Information "Detected az version: $cliVersion"

  $GraphBaseUri = $GraphBaseUri.TrimEnd('/')

  Write-Information "Logging in to az"
  $null = AzLogin

  Write-Information "Finding SCEPman's App Registration"
  $appregsc = RegisterAzureADApp -name $AzureADAppNameForSCEPman -appRoleAssignments $ScepmanManifest -hideApp $true -createIfNotExists $false
  $servicePrincipalScepmanId = CreateServicePrincipal -appId $($appregsc.appId)

  Write-Information "Allowing Service Principal to submit CSR requests to SCEPman API"
  $ScepManSubmitCSRPermission = $appregsc.appRoles.Where({ $_.value -eq $Role}, "First")
  if ($null -eq $ScepManSubmitCSRPermission) {
    throw "SCEPman has no role $Role in its $($appregsc.appRoles.Count) app roles. Please make sure this role to use an existing role like CSR.Request.Db."
  }

  $resourcePermissionsForApiClient = @([pscustomobject]@{'resourceId'=$servicePrincipalScepmanId;'appRoleId'=$($ScepManSubmitCSRPermission.id);'permissionLevel'=0})
  $null = SetManagedIdentityPermissions -principalId $ServicePrincipalId -resourcePermissions $resourcePermissionsForApiClient -GraphBaseUri $GraphBaseUri

  Write-Information "CSR submission permission assigned to service principal with id $ServicePrincipalId"
}