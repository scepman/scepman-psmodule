function RegisterAzureADApp($name, $manifest, $replyUrls = $null, $homepage = $null, $EnableIdToken = $false) {
  $azureAdAppReg = ConvertLinesToObject -lines $(az ad app list --filter "displayname eq '$name'" --query "[0]" --only-show-errors)
  if($null -eq $azureAdAppReg) {
      Write-Information "Creating app registration $name, as it does not exist yet"

      $azAppRegistrationCommand = "az ad app create --display-name '$name' --app-roles '$manifest'"
      if ($null -ne $replyUrls) {
        if (AzUsesAADGraph) {
          $azAppRegistrationCommand += " --reply-urls '$replyUrls'"
        } else {
          $azAppRegistrationCommand += " --web-redirect-uris '$replyUrls'"
        }
      }
      if ($null -ne $homepage) {
        if (AzUsesAADGraph) {
          $azAppRegistrationCommand += " --homepage '$homepage'"
        } else {
          $azAppRegistrationCommand += " --web-home-page-url '$homepage'"
        }
      }
      if (-not (AzUsesAADGraph)) {
        $azAppRegistrationCommand += " --sign-in-audience AzureADMyOrg"
        if ($EnableIdToken) {
          $azAppRegistrationCommand += " --enable-id-token-issuance"
        }
      }

      $azureAdAppReg = ConvertLinesToObject -lines $(ExecuteAzCommandRobustly -azCommand $azAppRegistrationCommand)
      Write-Verbose "Created app registration $name (App ID $($azureAdAppReg.appId))"

      # REVISIT: Once there is a solution for https://github.com/Azure/azure-cli/issues/22810, we can upload the logo
#      $graphEndpointForAppLogo = "https://graph.microsoft.com/v1.0/applications/$($azureAdAppReg.id)/logo"
#      az rest --method put --url $graphEndpointForAppLogo --body '@testlogo.png' --headers Content-Type=image/png
  } else {
    Write-Information "Existing app registration $name found (App ID $($azureAdAppReg.appId))"
  }

  return $azureAdAppReg
}

function CreateSCEPmanAppRegistration ($AzureADAppNameForSCEPman, $CertMasterServicePrincipalId) {

  Write-Information "Getting Azure AD app registration for SCEPman"
  # Register SCEPman App
  $appregsc = RegisterAzureADApp -name $AzureADAppNameForSCEPman -manifest $ScepmanManifest -hideApp $true
  $spsc = CreateServicePrincipal -appId $($appregsc.appId)
  if (AzUsesAADGraph) {
    $servicePrincipalScepmanId = $spsc.objectId
  } else { # Microsoft Graph
    $servicePrincipalScepmanId = $spsc.id
  }

  $ScepManSubmitCSRPermission = $appregsc.appRoles[0].id

  # Expose SCEPman API
  ExecuteAzCommandRobustly -azCommand "az ad app update --id $($appregsc.appId) --identifier-uris `"api://$($appregsc.appId)`""

  Write-Information "Allowing CertMaster to submit CSR requests to SCEPman API"
  $resourcePermissionsForCertMaster = @([pscustomobject]@{'resourceId'=$servicePrincipalScepmanId;'appRoleId'=$ScepManSubmitCSRPermission;})
  SetManagedIdentityPermissions -principalId $CertMasterServicePrincipalId -resourcePermissions $resourcePermissionsForCertMaster

  return $appregsc
}

function CreateCertMasterAppRegistration ($AzureADAppNameForCertMaster, $CertMasterBaseURL) {

  Write-Information "Getting Azure AD app registration for CertMaster"
  ### CertMaster App Registration

  # Register CertMaster App
  $appregcm = RegisterAzureADApp -name $AzureADAppNameForCertMaster -manifest $CertmasterManifest -replyUrls `"$CertMasterBaseURL/signin-oidc`" -hideApp $false -homepage $CertMasterBaseURL -EnableIdToken $true
  $null = CreateServicePrincipal -appId $($appregcm.appId)

  Write-Verbose "Adding Delegated permission to CertMaster App Registration"
  # Add Microsoft Graph's User.Read as delegated permission for CertMaster
  AddDelegatedPermissionToCertMasterApp -appId $appregcm.appId

  return $appregcm
}