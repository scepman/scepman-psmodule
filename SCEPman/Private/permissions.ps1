function GetServicePrincipal($appServiceNameParam, $resourceGroupParam, $slotNameParam = $null) {
    $identityShowParams = "";
    if($null -ne $slotNameParam) {
        $identityShowParams = "--slot", $slotNameParam
    }
    return ConvertLinesToObject -lines $(az webapp identity show --name $appServiceNameParam --resource-group $resourceGroupParam @identityShowParams)
}

function GetAzureResourceAppId($appId) {
    if (AzUsesAADGraph) {
        $queryParam = '[0].objectId'
    } else { # Microsoft Graph
        $queryParam = '[0].id'
    }

    return $(az ad sp list --filter "appId eq '$appId'" --query $queryParam --out tsv --only-show-errors)
}

function SetManagedIdentityPermissions($principalId, $resourcePermissions, $GraphBaseUri) {
    $graphEndpointForAppRoleAssignments = "$GraphBaseUri/v1.0/servicePrincipals/$principalId/appRoleAssignments"
    $alreadyAssignedPermissions = ExecuteAzCommandRobustly -azCommand "az rest --method get --uri '$graphEndpointForAppRoleAssignments' --headers 'Content-Type=application/json' --query 'value[].appRoleId' --output tsv"

    ForEach($resourcePermission in $resourcePermissions) {
        if($alreadyAssignedPermissions -contains $resourcePermission.appRoleId) {
            Write-Verbose "Permission is already there (ResourceID $($resourcePermission.resourceId), AppRoleId $($resourcePermission.appRoleId))"
        } else {
            Write-Verbose "Assigning new permission (ResourceID $($resourcePermission.resourceId), AppRoleId $($resourcePermission.appRoleId))"
            $bodyToAddPermission = "{'principalId': '$principalId','resourceId': '$($resourcePermission.resourceId)','appRoleId':'$($resourcePermission.appRoleId)'}"
            $null = ExecuteAzCommandRobustly -azCommand "az rest --method post --uri '$graphEndpointForAppRoleAssignments' --body `"$bodyToAddPermission`" --headers 'Content-Type=application/json'" -principalId $principalId -appRoleId $resourcePermission.appRoleId -GraphBaseUri $GraphBaseUri
        }
    }
}

function GetSCEPmanResourcePermissions() {
    $graphResourceId = GetAzureResourceAppId -appId $MSGraphAppId
    $intuneResourceId = GetAzureResourceAppId -appId $IntuneAppId

    ### Managed identity permissions for SCEPman
    if ($null -eq $intuneResourceId) {  # When not using Intune at all (e.g. only JAMF), there is IntuneAppId can be $null
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
    return ConvertLinesToObject -lines $(az ad app list --filter "displayname eq '$name'" --query "[0]")
}

function CreateServicePrincipal($appId, [bool]$hideApp) {
    $azOutput = az ad sp list --filter "appId eq '$appId'" --query "[0]" --only-show-errors
    $sp = ConvertLinesToObject -lines $(CheckAzOutput -azOutput $azOutput -fThrowOnError $true)
    if($null -eq $sp) {
        #App Registration SP doesn't exist.
        $sp = ConvertLinesToObject -lines $(ExecuteAzCommandRobustly -azCommand "az ad sp create --id $appId")
        if ($hideApp) {
            $null = ExecuteAzCommandRobustly -azCommand "az ad sp update --id $appId --add tags HideApp"
        }
    }
    return $sp
}

function AddDelegatedPermissionToCertMasterApp($appId) {
    $azOutput = az ad app permission list --id $appId --query "[0]" 2>&1
    $certMasterPermissions = ConvertLinesToObject -lines $(CheckAzOutput -azOutput $azOutput -fThrowOnError $true)
    if($null -eq ($certMasterPermissions.resourceAccess | Where-Object { $_.id -eq $MSGraphUserReadPermission })) {
        $null = ExecuteAzCommandRobustly -azCommand "az ad app permission add --id $appId --api $MSGraphAppId --api-permissions `"$MSGraphUserReadPermission=Scope`" --only-show-errors"
    }
    $certMasterPermissionsGrantsString = ConvertLinesToObject -lines $(CheckAzOutput(az ad app permission list-grants --id $appId --query "[0].scope" 2>&1))
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
        $null = ExecuteAzCommandRobustly -azCommand $azGrantPermissionCommand
    }
}