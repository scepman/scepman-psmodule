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
    $permissionLevelFail = [Int32]::MaxValue
    $permissionLevelReached = -1

    $graphEndpointForAppRoleAssignments = "$GraphBaseUri/v1.0/servicePrincipals/$principalId/appRoleAssignments"
    $alreadyAssignedPermissions = ExecuteAzCommandRobustly -azCommand "az rest --method get --uri '$graphEndpointForAppRoleAssignments' --headers 'Content-Type=application/json' --query 'value[].appRoleId' --output tsv"

    ForEach($resourcePermission in $resourcePermissions) {
        if($alreadyAssignedPermissions -contains $resourcePermission.appRoleId) {
            Write-Verbose "Permission is already there (ResourceID $($resourcePermission.resourceId), AppRoleId $($resourcePermission.appRoleId))"
            if ($resourcePermission.permissionLevel -gt $permissionLevelReached) {
                $permissionLevelReached = $resourcePermission.permissionLevel
            }
        } else {
            Write-Verbose "Assigning new permission (ResourceID $($resourcePermission.resourceId), AppRoleId $($resourcePermission.appRoleId))"
            $bodyToAddPermission = "{'principalId': '$principalId','resourceId': '$($resourcePermission.resourceId)','appRoleId':'$($resourcePermission.appRoleId)'}"
            $azCommand = "az rest --method post --uri '$graphEndpointForAppRoleAssignments' --body `"$bodyToAddPermission`" --headers 'Content-Type=application/json'"
            if ($SkipAppRoleAssignments) {
                Write-Warning "Skipping app role assignment (please execute manually): $azCommand"
                if ($resourcePermission.permissionLevel -lt $permissionLevelFail) {
                    $permissionLevelFail = $resourcePermission.permissionLevel
                }
            } else {
                try {
                    $null = ExecuteAzCommandRobustly -azCommand $azCommand -principalId $principalId -appRoleId $resourcePermission.appRoleId -GraphBaseUri $GraphBaseUri
                    if ($resourcePermission.permissionLevel -gt $permissionLevelReached) {
                        $permissionLevelReached = $resourcePermission.permissionLevel
                    }
                }
                catch {
                    $exceptionMessage = $_.ToString()
                    if ($exceptionMessage.Contains($PERMISSION_DOES_NOT_EXIST)) {
                        Write-Warning "The app role $($resourcePermission.appRoleId) does not exist in application $($resourcePermission.resourceId) already exists. It is required for permission level $($resourcePermission.permissionLevel)."
                        if ($resourcePermission.permissionLevel -eq 0) {
                            Write-Error "Couldn't assign permission of permission level 0"
                            throw $_
                        } else {
                            if ($resourcePermission.permissionLevel -lt $permissionLevelFail) {
                                $permissionLevelFail = $resourcePermission.permissionLevel
                            }
                        }
                    } else {
                        throw $_
                    }
                }
            }
        }
    }

    if ($permissionLevelReached -ge $permissionLevelFail) {
        return $permissionLevelFail - 1
    } else {
        return $permissionLevelReached
    }
}

function GetSCEPmanResourcePermissions() {
    $graphResourceId = GetAzureResourceAppId -appId $MSGraphAppId
    $intuneResourceId = GetAzureResourceAppId -appId $IntuneAppId

    $permissions = @([pscustomobject]@{'resourceId'=$graphResourceId;'appRoleId'=$MSGraphDirectoryReadAllPermission; 'permissionLevel' = 0;},
        [pscustomobject]@{'resourceId'=$graphResourceId;'appRoleId'=$MSGraphDeviceManagementReadPermission; 'permissionLevel' = 1;},
        [pscustomobject]@{'resourceId'=$graphResourceId;'appRoleId'=$MSGraphDeviceManagementConfigurationReadAll; 'permissionLevel' = 1;},
        [pscustomobject]@{'resourceId'=$graphResourceId;'appRoleId'=$MSGraphIdentityRiskyUserReadPermission; 'permissionLevel' = 2;}
    )

    ### Managed identity permissions for SCEPman
    if ($null -ne $intuneResourceId) {  # When not using Intune at all (e.g. only JAMF), the IntuneAppId can be $null
        $permissions += [pscustomobject]@{'resourceId'=$intuneResourceId;'appRoleId'=$IntuneSCEPChallengePermission; 'permissionLevel' = 0;}
    } else {
        Write-Warning "Intune is not used. Skipping Intune permissions."
    }

    return $permissions
}

function GetCertMasterResourcePermissions() {
    $graphResourceId = GetAzureResourceAppId -appId $MSGraphAppId

    ### Managed identity permissions for CertMaster
    return @([pscustomobject]@{'resourceId'=$graphResourceId;'appRoleId'=$MSGraphDeviceManagementReadPermission; 'permissionLevel' = 2;},
             [pscustomobject]@{'resourceId'=$graphResourceId;'appRoleId'=$MSGraphDeviceManagementConfigurationReadAll; 'permissionLevel' = 2;}
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

function Get-AccessTokenForApp($scope) {
    Write-Warning "Acquiring token for scope $scope. This can expose unencrypted token information in memory or verbose logs. Please use with caution."
    return ExecuteAzCommandRobustly -callAzNatively -azCommand $('account', 'get-access-token', '--scope', $scope, '--query', 'accessToken', '--output', 'tsv') | ConvertTo-SecureString -AsPlainText -Force
}