function GetServicePrincipal($appServiceNameParam, $resourceGroupParam, $slotNameParam = $null) {
    $identityShowParams = "";
    if($null -ne $slotNameParam) {
        $identityShowParams = "--slot '$slotNameParam'"
    }
    return ExecuteAzCommandRobustly -azCommand "az webapp identity show --name $appServiceNameParam --resource-group $resourceGroupParam $identityShowParams" | Convert-LinesToObject
}

function GetUserAssignedPrincipalIdsFromServicePrincipal($servicePrincipal) {
    $userAssignedPrincipalIds = @()
    if($null -ne $servicePrincipal.userAssignedIdentities) {
        foreach ($userAssignedIdentity in $servicePrincipal.userAssignedIdentities.psobject.Properties) {
            $userAssignedPrincipalIds += $servicePrincipal.userAssignedIdentities.($userAssignedIdentity.Name).principalId
        }
    }
    Write-Output $userAssignedPrincipalIds -NoEnumerate # The switch prevents an empty array to be returned as $null, otherwise this is similar to return
}

function GetAzureResourceAppId($appId) {
    if (AzUsesAADGraph) {
        $queryParam = '[0].objectId'
    } else { # Microsoft Graph
        $queryParam = '[0].id'
    }

    return $(az ad sp list --filter "appId eq '$appId'" --query $queryParam --out tsv --only-show-errors)
}

function SetManagedIdentityPermissions($principalId, $resourcePermissions, $GraphBaseUri, $SkipAppRoleAssignments = $false) {
    $allPermissionsAreGranted = $true  # Assume all permissions are granted

    $graphEndpointForAppRoleAssignments = "$GraphBaseUri/v1.0/servicePrincipals/$principalId/appRoleAssignments"
    $alreadyAssignedPermissions = ExecuteAzCommandRobustly -azCommand "az rest --method get --uri '$graphEndpointForAppRoleAssignments' --headers 'Content-Type=application/json' --query 'value[].appRoleId' --output tsv"

    ForEach($resourcePermission in $resourcePermissions) {
        if($alreadyAssignedPermissions -contains $resourcePermission.appRoleId) {
            Write-Verbose "Permission is already there (ResourceID $($resourcePermission.resourceId), AppRoleId $($resourcePermission.appRoleId))"
        } else {
            Write-Verbose "Assigning new permission (ResourceID $($resourcePermission.resourceId), AppRoleId $($resourcePermission.appRoleId))"
            $bodyToAddPermission = "{'principalId': '$principalId','resourceId': '$($resourcePermission.resourceId)','appRoleId':'$($resourcePermission.appRoleId)'}"
            $azCommand = "az rest --method post --uri '$graphEndpointForAppRoleAssignments' --body `"$bodyToAddPermission`" --headers 'Content-Type=application/json'"
            if ($SkipAppRoleAssignments) {
                Write-Warning "Skipping app role assignment (please execute manually): $azCommand"
                $allPermissionsAreGranted = $false
            } else {
                $null = ExecuteAzCommandRobustly -azCommand $azCommand -principalId $principalId -appRoleId $resourcePermission.appRoleId -GraphBaseUri $GraphBaseUri
            }
        }
    }

    return $allPermissionsAreGranted
}

function GetSCEPmanResourcePermissions() {
    $graphResourceId = GetAzureResourceAppId -appId $MSGraphAppId
    $intuneResourceId = GetAzureResourceAppId -appId $IntuneAppId

    ### Managed identity permissions for SCEPman
    if ($null -eq $intuneResourceId) {  # When not using Intune at all (e.g. only JAMF), the IntuneAppId can be $null
        return @([pscustomobject]@{'resourceId'=$graphResourceId;'appRoleId'=$MSGraphDirectoryReadAllPermission;},
                [pscustomobject]@{'resourceId'=$graphResourceId;'appRoleId'=$MSGraphDeviceManagementReadPermission;},
                [pscustomobject]@{'resourceId'=$graphResourceId;'appRoleId'=$MSGraphDeviceManagementConfigurationReadAll;},
                [pscustomobject]@{'resourceId'=$graphResourceId;'appRoleId'=$MSGraphIdentityRiskyUserReadPermission;}
            )
    } else {
        return @([pscustomobject]@{'resourceId'=$graphResourceId;'appRoleId'=$MSGraphDirectoryReadAllPermission;},
                [pscustomobject]@{'resourceId'=$graphResourceId;'appRoleId'=$MSGraphDeviceManagementReadPermission;},
                [pscustomobject]@{'resourceId'=$graphResourceId;'appRoleId'=$MSGraphDeviceManagementConfigurationReadAll;},
                [pscustomobject]@{'resourceId'=$graphResourceId;'appRoleId'=$MSGraphIdentityRiskyUserReadPermission;},
                [pscustomobject]@{'resourceId'=$intuneResourceId;'appRoleId'=$IntuneSCEPChallengePermission;}
            )
    }
}

function GetCertMasterResourcePermissions() {
    $graphResourceId = GetAzureResourceAppId -appId $MSGraphAppId

    ### Managed identity permissions for CertMaster
    return @([pscustomobject]@{'resourceId'=$graphResourceId;'appRoleId'=$MSGraphDeviceManagementReadPermission;},
             [pscustomobject]@{'resourceId'=$graphResourceId;'appRoleId'=$MSGraphDeviceManagementConfigurationReadAll;}
    )
}

function GetAzureADApp($name) {
    return Convert-LinesToObject -lines $(az ad app list --filter "displayname eq '$name'" --query "[0]")
}

function CreateServicePrincipal($appId, [bool]$hideApp) {
    $azOutput = az ad sp list --filter "appId eq '$appId'" --query "[0]" --only-show-errors
    $sp = Convert-LinesToObject -lines $(CheckAzOutput -azOutput $azOutput -fThrowOnError $true)
    if($null -eq $sp) {
        #App Registration SP doesn't exist.
        $sp = Convert-LinesToObject -lines $(ExecuteAzCommandRobustly -azCommand "az ad sp create --id $appId")
        if ($hideApp) {
            $null = ExecuteAzCommandRobustly -azCommand "az ad sp update --id $appId --add tags HideApp"
        }
    }
    if ($sp.appRoleAssignmentRequired -eq $false) {
        Write-Verbose "Updating appRoleAssignmentRequired to true for application $appId"
        $null = ExecuteAzCommandRobustly -azCommand "az ad sp update --id $appId --set appRoleAssignmentRequired=true"
    }

    if (AzUsesAADGraph) {
      return $sp.objectId
    } else { # Microsoft Graph
      return $sp.id
    }
}

function AddDelegatedPermissionToCertMasterApp($appId, $SkipAutoGrant) {
    $azOutput = az ad app permission list --id $appId --query "[0]" 2>&1
    $certMasterPermissions = Convert-LinesToObject -lines $(CheckAzOutput -azOutput $azOutput -fThrowOnError $true)
    if($null -eq ($certMasterPermissions.resourceAccess | Where-Object { $_.id -eq $MSGraphUserReadPermission })) {
        $null = ExecuteAzCommandRobustly -azCommand "az ad app permission add --id $appId --api $MSGraphAppId --api-permissions `"$MSGraphUserReadPermission=Scope`" --only-show-errors"
    }
    $certMasterPermissionsGrantsString = Convert-LinesToObject -lines $(CheckAzOutput(az ad app permission list-grants --id $appId --query "[0].scope" 2>&1))
    if ($null -eq $certMasterPermissionsGrantsString) {
        $requiresPermissionGrant = $true
    } else {
        $certMasterPermissionsGrants = $certMasterPermissionsGrantsString.ToString().Split(" ")
        if(($certMasterPermissionsGrants -contains "User.Read") -eq $false) {
            $requiresPermissionGrant = $true
        } else {
            Write-Verbose "CertMaster already has the delegated permission User.Read"
            $requiresPermissionGrant = $false
        }
    }
    if($true -eq $requiresPermissionGrant) {
        $azGrantPermissionCommand = "az ad app permission grant --id $appId --api $MSGraphAppId --scope `"User.Read`""
        if (AzUsesAADGraph) {
            $azGrantPermissionCommand += ' --expires "never"'
        }
        if ($SkipAutoGrant) {
            Write-Warning "Please execute the following command manually to grant CertMaster the delegated permission User.Read: $azGrantPermissionCommand"
        } else {
            $null = ExecuteAzCommandRobustly -azCommand $azGrantPermissionCommand
        }
    }
}