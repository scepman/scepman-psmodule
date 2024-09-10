function RegisterAzureADApp($name, $appRoleAssignments, $replyUrls = $null, $homepage = $null, $EnableIdToken = $false, $createIfNotExists = $true) {
  $azureAdAppReg = Convert-LinesToObject -lines $(az ad app list --filter "displayname eq '$name'" --query "[0]" --only-show-errors)

  if($null -eq $azureAdAppReg) {
    if ($createIfNotExists) {
      Write-Information "Creating app registration $name, as it does not exist yet"

      $appRoleManifestJson = HashTable2AzJson -psHashTable $appRoleAssignments
      $azAppRegistrationCommand = "az ad app create --display-name '$name' --app-roles '$appRoleManifestJson'"
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

      $azureAdAppReg = Convert-LinesToObject -lines $(ExecuteAzCommandRobustly -azCommand $azAppRegistrationCommand)
      Write-Verbose "Created app registration $name (App ID $($azureAdAppReg.appId))"

        # Check whether the AppRoles were added correctly
      if ($azureAdAppReg.appRoles.Count -le 0) {
        Write-Error "The app registration $name (App ID $($azureAdAppReg.appId) has no app roles. This is likely an error that must be fixed."
      }

      # REVISIT: Once there is a solution for https://github.com/Azure/azure-cli/issues/22810, we can upload the logo
#      $graphEndpointForAppLogo = "https://graph.microsoft.com/v1.0/applications/$($azureAdAppReg.id)/logo"
#      az rest --method put --url $graphEndpointForAppLogo --body '@testlogo.png' --headers Content-Type=image/png
    } else {
      throw "App registration $name does not exist yet. Please run Commplete-SCEPmanInstallation first."
    }
  } else {
    Write-Information "Existing app registration $name found (App ID $($azureAdAppReg.appId))"

    # check whether we need to update the roles
    $anything2Update = $false
    $updatedAppRoles = $azureAdAppReg.appRoles
    foreach ($requiredAppRole in $appRoleAssignments) {
      $role2Update = $updatedAppRoles.Where({ $_.value -eq $requiredAppRole.value}, "First")
      if ($role2Update.Count -eq 0) {
        $anything2Update = $true
        Write-Verbose "Required role $($requiredAppRole.displayName) will be added to existing app registration"
        $updatedAppRoles += ,$requiredAppRole
      }
    }

    if ($anything2Update) {
      Write-Information "Adding new roles to app registration $name"
      $appRolesJson = HashTable2AzJson -psHashTable $updatedAppRoles
      ExecuteAzCommandRobustly "az ad app update --id $($azureAdAppReg.appId) --app-roles '$appRolesJson'"

        # Reload app registration with new roles
      $azureAdAppReg = Convert-LinesToObject -lines $(az ad app show --id $azureAdAppReg.id)
    }

    if ($null -ne $replyUrls) {
      $existingReplyUrls = $azureAdAppReg.web.redirectUris
      $newReplyUrls = $replyUrls -split " "
      $replyUrlsToAdd = $newReplyUrls | Where-Object { $existingReplyUrls -notcontains $_ }
      if ($replyUrlsToAdd.Count -gt 0) {
        Write-Information "Adding reply URLs to app registration $name"
        $azCommandToAddReplyUrls = @("ad", "app", "update", "--id", $azureAdAppReg.appId)
        if (AzUsesAADGraph) {
          $azCommandToAddReplyUrls += "--reply-urls"
        } else {
          $azCommandToAddReplyUrls += "--web-redirect-uris"
          # ExecuteAzCommandRobustly -callAzNatively -azCommand @("ad", "app", "update", "--id", $azureAdAppReg.appId, "--web-home-page-url", $homepage, "--web-redirect-uris", $allReplyUrls)
        }
        $azCommandToAddReplyUrls += $existingReplyUrls + $replyUrlsToAdd
        ExecuteAzCommandRobustly -callAzNatively -azCommand $azCommandToAddReplyUrls
      }
    }
    $azureAdAppReg.web.redirectUris
  }

  return $azureAdAppReg
}

function CreateSCEPmanAppRegistration ($AzureADAppNameForSCEPman, $CertMasterServicePrincipalId, $GraphBaseUri) {
  Write-Information "Getting Azure AD app registration for SCEPman"
  # Register SCEPman App
  $appregsc = RegisterAzureADApp -name $AzureADAppNameForSCEPman -appRoleAssignments $ScepmanManifest -hideApp $true

  $servicePrincipalScepmanId = CreateServicePrincipal -appId $($appregsc.appId)

  # Expose SCEPman API
  ExecuteAzCommandRobustly -azCommand "az ad app update --id $($appregsc.appId) --identifier-uris `"api://$($appregsc.appId)`""

  Write-Information "Allowing CertMaster to submit CSR requests to SCEPman API"
  $ScepManSubmitCSRPermission = $appregsc.appRoles.Where({ $_.value -eq "CSR.Request"}, "First")

  if (!$ScepManSubmitCSRPermission) {
    throw "SCEPman has no role CSR.Request in its $($appregsc.appRoles.Count) app roles. Certificate Master needs to be assigned this role."
  }

  $resourcePermissionsForCertMaster = @([pscustomobject]@{'resourceId'=$servicePrincipalScepmanId;'appRoleId'=$($ScepManSubmitCSRPermission.id);'permissionLevel'=0})
  $null = SetManagedIdentityPermissions -principalId $CertMasterServicePrincipalId -resourcePermissions $resourcePermissionsForCertMaster -GraphBaseUri $GraphBaseUri

  return $appregsc
}

function CreateCertMasterAppRegistration ($AzureADAppNameForCertMaster, $CertMasterBaseURLs, $SkipAutoGrant = $false) {

  Write-Information "Getting Azure AD app registration for CertMaster"
  ### CertMaster App Registration

  $signInUrlArray = $CertMasterBaseURLs | ForEach-Object { "$_/signin-oidc" }
  $spaceSeparatedSignInUrls = $signInUrlArray -join " "

  # Register CertMaster App
  $appregcm = RegisterAzureADApp -name $AzureADAppNameForCertMaster -appRoleAssignments $CertmasterManifest -replyUrls $spaceSeparatedSignInUrls -hideApp $false -homepage $CertMasterBaseURL -EnableIdToken $true
  $null = CreateServicePrincipal -appId $($appregcm.appId)

  # Expose CertMaster API
  ExecuteAzCommandRobustly -azCommand "az ad app update --id $($appregcm.appId) --identifier-uris `"api://$($appregcm.appId)`""

  Write-Verbose "Adding Delegated permission to CertMaster App Registration"
  # Add Microsoft Graph's User.Read as delegated permission for CertMaster
  AddDelegatedPermissionToCertMasterApp -appId $appregcm.appId -SkipAutoGrant $SkipAutoGrant

  return $appregcm
}

<#
.SYNOPSIS

.DESCRIPTION
Adds az as an Authorized CLient Application to an existing App Registration. Returns $true if the authorization was added, $false if it already existed.
#>
function Add-AzAsTrustedClientApplication ($AppId) {
  $AppJson = ExecuteAzCommandRobustly -callAzNatively -azCommand @('ad', 'app', 'show', '--id', $AppId)
  $AppObject = Convert-LinesToObject -Lines $AppJson

  $existingAzAuthorization = $AppObject.api.preAuthorizedApplications | Where-Object { $_.appId -eq $AzAppId }
  if ($null -eq $existingAzAuthorization) {
    Write-Information "Adding az as authorized application"
    $AccessApplicationPermissionId = $AppObject.api.oauth2PermissionScopes | Where-Object { $_.value -eq 'user_impersonation' } | Select-Object -ExpandProperty id
    if ($existingAzAuthorization.Count -eq 0) {
      $existingAzAuthorization = [System.Collections.ArrayList]@()
    }
    $null = $existingAzAuthorization.Add(@{ 'appId' = $AzAppId; 'permissionIds' = @($AccessApplicationPermissionId) })
    $previousPreAuthorizationsInner = ConvertTo-Json -InputObject $existingAzAuthorization -Compress
    $previousPreAuthorizationsBody = "{'api':{'preAuthorizedApplications':$($previousPreAuthorizationsInner.Replace("delegatedPermissionIds", "permissionIds").Replace('"', "'"))}}"

    $null = ExecuteAzCommandRobustly -callAzNatively -azCommand @('rest', '--method', 'patch', '--uri', "https://graph.microsoft.com/beta/applications/$($AppObject.id)", '--body', $previousPreAuthorizationsBody, '--headers', 'Content-Type=application/json')

    return $true
  } else {
    return $false
  }
}

function Remove-AsAsTrustedClientApplication ($AppId) {
  $AppJson = ExecuteAzCommandRobustly -callAzNatively -azCommand @('ad', 'app', 'show', '--id', $AppId)
  $AppObject = Convert-LinesToObject -Lines $AppJson

  $authorizationsWithoutAz = $AppObject.api.preAuthorizedApplications | Where-Object { $_.appId -ne $AzAppId }

  if ($null -eq $authorizationsWithoutAz) {
    $authorizationsWithoutAz = @()
  }

  $previousPreAuthorizationsInner = ConvertTo-Json -InputObject $authorizationsWithoutAz -Compress
  $previousPreAuthorizationsBody = "{'api':{'preAuthorizedApplications':$($previousPreAuthorizationsInner.Replace("delegatedPermissionIds", "permissionIds").Replace('"', "'"))}}"

  $null = ExecuteAzCommandRobustly -callAzNatively -azCommand @('rest', '--method', 'patch', '--uri', "https://graph.microsoft.com/beta/applications/$($AppObject.id)", '--body', $previousPreAuthorizationsBody, '--headers', 'Content-Type=application/json')
}