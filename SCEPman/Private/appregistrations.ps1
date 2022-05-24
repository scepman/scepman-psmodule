function RegisterAzureADApp($name, $manifest, $replyUrls = $null) {
  $azureAdAppReg = ConvertLinesToObject -lines $(az ad app list --filter "displayname eq '$name'" --query "[0]" --only-show-errors)
  if($null -eq $azureAdAppReg) {
      #App Registration doesn't exist.
      if($null -eq $replyUrls) {
          $azureAdAppReg = ConvertLinesToObject -lines $(ExecuteAzCommandRobustly -azCommand "az ad app create --display-name '$name' --app-roles '$manifest'")
      }
      else {
          $azureAdAppReg = ConvertLinesToObject -lines $(ExecuteAzCommandRobustly -azCommand "az ad app create --display-name '$name' --app-roles '$manifest' --reply-urls '$replyUrls'")
      }
  }
  return $azureAdAppReg
}

function CreateSCEPmanAppRegistration ($AzureADAppNameForSCEPman, $CertMasterServicePrincipalId) {

  Write-Information "Creating Azure AD app registration for SCEPman"
  # Register SCEPman App
  $appregsc = RegisterAzureADApp -name $AzureADAppNameForSCEPman -manifest $ScepmanManifest -hideApp $true
  $spsc = CreateServicePrincipal -appId $($appregsc.appId)
  
  $ScepManSubmitCSRPermission = $appregsc.appRoles[0].id
  
  # Expose SCEPman API
  ExecuteAzCommandRobustly -azCommand "az ad app update --id $($appregsc.appId) --identifier-uris `"api://$($appregsc.appId)`""
  
  Write-Information "Allowing CertMaster to submit CSR requests to SCEPman API"
  # Allow CertMaster to submit CSR requests to SCEPman API
  $resourcePermissionsForCertMaster = @([pscustomobject]@{'resourceId'=$($spsc.objectId);'appRoleId'=$ScepManSubmitCSRPermission;})
  SetManagedIdentityPermissions -principalId $CertMasterServicePrincipal -resourcePermissions $resourcePermissionsForCertMaster
}

function CreateCertMasterAppRegistration ($AzureADAppNameForCertMaster, $CertMasterBaseURL) {

  Write-Information "Creating Azure AD app registration for CertMaster"
  ### CertMaster App Registration
  
  # Register CertMaster App
  $appregcm = RegisterAzureADApp -name $AzureADAppNameForCertMaster -manifest $CertmasterManifest -replyUrls `"$CertMasterBaseURL/signin-oidc`" -hideApp $false
  $null = CreateServicePrincipal -appId $($appregcm.appId)
  
  Write-Verbose "Adding Delegated permission to CertMaster App Registration"
  # Add Microsoft Graph's User.Read as delegated permission for CertMaster
  AddDelegatedPermissionToCertMasterApp -appId $appregcm.appId
}