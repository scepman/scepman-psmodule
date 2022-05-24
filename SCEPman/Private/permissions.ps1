function GetServicePrincipal($appServiceNameParam, $resourceGroupParam, $slotNameParam = $null) {
    $identityShowParams = "";
    if($null -ne $slotNameParam) {
        $identityShowParams = "--slot", $slotNameParam
    }
    return ConvertLinesToObject -lines $(az webapp identity show --name $appServiceNameParam --resource-group $resourceGroupParam @identityShowParams)
}

function GetAzureResourceAppId($appId) {
    return $(az ad sp list --filter "appId eq '$appId'" --query [0].objectId --out tsv --only-show-errors) # REVISIT: Show Warnings, too, when MS Graph became standard
}

function SetManagedIdentityPermissions($principalId, $resourcePermissions) {
    $graphEndpointForAppRoleAssignments = "https://graph.microsoft.com/v1.0/servicePrincipals/$($principalId)/appRoleAssignments"
    $alreadyAssignedPermissions = ExecuteAzCommandRobustly -azCommand "az rest --method get --uri '$graphEndpointForAppRoleAssignments' --headers 'Content-Type=application/json' --query 'value[].appRoleId' --output tsv"

    ForEach($resourcePermission in $resourcePermissions) {
        if(($alreadyAssignedPermissions -contains $resourcePermission.appRoleId) -eq $false) {
            $bodyToAddPermission = "{'principalId': '$($principalId)','resourceId': '$($resourcePermission.resourceId)','appRoleId':'$($resourcePermission.appRoleId)'}"
            $null = ExecuteAzCommandRobustly -azCommand "az rest --method post --uri '$graphEndpointForAppRoleAssignments' --body `"$bodyToAddPermission`" --headers 'Content-Type=application/json'" -principalId $principalId -appRoleId $resourcePermission.appRoleId
        }
    }
}

function GetAzureADApp($name) {
    return ConvertLinesToObject -lines $(az ad app list --filter "displayname eq '$name'" --query "[0]")
}

function CreateServicePrincipal($appId, [bool]$hideApp) {
    $sp = ConvertLinesToObject -lines $(az ad sp list --filter "appId eq '$appId'" --query "[0]" --only-show-errors)
    if($null -eq $sp) {
        #App Registration SP doesn't exist.
        $sp = ConvertLinesToObject -lines $(ExecuteAzCommandRobustly -azCommand "az ad sp create --id $appId")
        if ($hideApp) {
            $null = ExecuteAzCommandRobustly -azCommand "az ad sp update --id $appId --add tags HideApp"
        }
    } else {
        return $sp
    }
}

function AddDelegatedPermissionToCertMasterApp($appId) {
    $certMasterPermissions = ConvertLinesToObject -lines $(CheckAzOutput (az ad app permission list --id $appId --query "[0]" 2>&1))
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
        $null = ExecuteAzCommandRobustly -azCommand "az ad app permission grant --id $appId --api $MSGraphAppId --scope `"User.Read`" --expires `"never`""
    }
}