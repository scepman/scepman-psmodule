function CreateSCEPmanAppRegistration ($AzureADAppNameForSCEPman, $CertMasterServicePrincipalId) {

  Write-Information "Creating Azure AD app registration for SCEPman"
  # Register SCEPman App
  $appregsc = RegisterAzureADApp -name $AzureADAppNameForSCEPman -manifest $ScepmanManifest
  $spsc = CreateServicePrincipal -appId $($appregsc.appId)
  
  $ScepManSubmitCSRPermission = $appregsc.appRoles[0].id
  
  # Expose SCEPman API
  ExecuteAzCommandRobustly -azCommand "az ad app update --id $($appregsc.appId) --identifier-uris `"api://$($appregsc.appId)`""
  
  Write-Information "Allowing CertMaster to submit CSR requests to SCEPman API"
  # Allow CertMaster to submit CSR requests to SCEPman API
  $resourcePermissionsForCertMaster = @([pscustomobject]@{'resourceId'=$($spsc.objectId);'appRoleId'=$ScepManSubmitCSRPermission;})
  SetManagedIdentityPermissions -principalId $CertMasterServicePrincipal -resourcePermissions $resourcePermissionsForCertMaster
}