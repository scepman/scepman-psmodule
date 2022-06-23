
function GetStorageAccount ($ResourceGroup) {
    $storageaccounts = ConvertLinesToObject -lines $(az graph query -q "Resources | where type == 'microsoft.storage/storageaccounts' and resourceGroup == '$ResourceGroup' | project name, resourceGroup, primaryEndpoints = properties.primaryEndpoints")
    if($storageaccounts.count -gt 0) {
        $potentialStorageAccountName = Read-Host "We have found one or more existing storage accounts in the resource group $ResourceGroup. Please hit enter now if you still want to create a new storage account or enter the name of the storage account you would like to use, and then hit enter"
        if(!$potentialStorageAccountName) {
            Write-Information "User selected to create a new storage account"
            return $null
        } else {
            $potentialStorageAccount = $storageaccounts.data | Where-Object { $_.name -eq $potentialStorageAccountName }
            if($null -eq $potentialStorageAccount) {
                Write-Error "We couldn't find a storage account with name $potentialStorageAccountName in resource group $ResourceGroup. Please try to re-run the script"
                throw "We couldn't find a storage account with name $potentialStorageAccountName in resource group $ResourceGroup. Please try to re-run the script"
            } else {
                return $potentialStorageAccount
            }
        }
    }
    else {
        Write-Warning "Unable to determine the storage account"
        return $null
    }
}

function GetExistingStorageAccount ($dataTableEndpoint) {
    $storageAccounts = ConvertLinesToObject -lines $(az graph query -q "Resources | where type == 'microsoft.storage/storageaccounts' and properties.primaryEndpoints.table startswith '$($dataTableEndpoint.TrimEnd('/'))' | project name, resourceGroup, primaryEndpoints = properties.primaryEndpoints")
    Write-Debug "When searching for Storage Account $dataTableEndpoint, $($storageAccounts.count) accounts look like the searched one"
    $storageAccounts = $storageAccounts.data | Where-Object { $_.primaryEndpoints.table.TrimEnd('/') -eq $dataTableEndpoint.TrimEnd('/')}
    if ($null -ne $storageAccounts.count) { # In PS 7 (?), $storageAccounts is an array; In PS 5, $null has a count property with value 0
        if ($storageAccounts.count -gt 0) { # must be one because the Table Endpoint is unique
            return $storageAccounts[0]
        } else {
            return $null
        }
    } else { # In PS 5, $storageAccounts is an object if it is only one
        return $storageAccounts
    }
}

function SetStorageAccountPermissions ($SubscriptionId, $ScStorageAccount, $servicePrincipals) {
    Write-Information "Setting permissions in storage account for $($servicePrincipals.Length) App Service identities"

    $SAScope = "/subscriptions/$SubscriptionId/resourceGroups/$($ScStorageAccount.resourceGroup)/providers/Microsoft.Storage/storageAccounts/$($ScStorageAccount.name)"
    Write-Debug "Storage Account Scope: $SAScope"
    ForEach($tempServicePrincipal in $servicePrincipals) {
        Write-Information "Setting Storage account permission for principal id $tempServicePrincipal"
        $null = CheckAzOutput(az role assignment create --role 'Storage Table Data Contributor' --assignee-object-id $tempServicePrincipal --assignee-principal-type 'ServicePrincipal' --scope $SAScope 2>&1)
    }
}

function CreateScStorageAccount ($SubscriptionId, $ResourceGroup, $servicePrincipals) {
    $ScStorageAccount = GetStorageAccount -ResourceGroup $ResourceGroup
    if($null -eq $ScStorageAccount) {
        Write-Information 'Storage account not found. We will create one now'
        $storageAccountName = $ResourceGroup.ToLower() -replace '[^a-z0-9]',''
        if($storageAccountName.Length -gt 19) {
            $storageAccountName = $storageAccountName.Substring(0,19)
        }
        $storageAccountName = "stg$($storageAccountName)cm"
        $potentialStorageAccountName = Read-Host "Please hit enter now if you want to create the storage account with name $storageAccountName or enter the name of your choice, and then hit enter"
        if($potentialStorageAccountName) {
            $storageAccountName = $potentialStorageAccountName
        }
        $ScStorageAccount = ConvertLinesToObject -lines $(az storage account create --name $storageAccountName --resource-group $ResourceGroup --sku 'Standard_LRS' --kind 'StorageV2' --access-tier 'Hot' --allow-blob-public-access $true --allow-cross-tenant-replication $false --allow-shared-key-access $false --enable-nfs-v3 $false --min-tls-version 'TLS1_2' --publish-internet-endpoints $false --publish-microsoft-endpoints $false --routing-choice 'MicrosoftRouting' --https-only $true --only-show-errors)
        if($null -eq $ScStorageAccount) {
            Write-Error 'Storage account not found and we are unable to create one. Please check logs for more details before re-running the script'
            throw 'Storage account not found and we are unable to create one. Please check logs for more details before re-running the script'
        }
        Write-Information "Storage account $storageAccountName created"
    }

    SetStorageAccountPermissions -SubscriptionId $SubscriptionId -ScStorageAccount $ScStorageAccount -servicePrincipals $servicePrincipals

    return $ScStorageAccount
}

function GetSCEPmanStorageAccountConfig( $SCEPmanResourceGroup, $SCEPmanAppServiceName, $DeploymentSlotName) {
    if ($null -eq $DeploymentSlotName) {
        return az webapp config appsettings list --name $SCEPmanAppServiceName --resource-group $SCEPmanResourceGroup --query "[?name=='AppConfig:CertificateStorage:TableStorageEndpoint'].value | [0]"
    } else {
        return az webapp config appsettings list --name $SCEPmanAppServiceName --resource-group $SCEPmanResourceGroup --query "[?name=='AppConfig:CertificateStorage:TableStorageEndpoint'].value | [0]" --slot $DeploymentSlotName
    }
}

function SetTableStorageEndpointsInScAndCmAppSettings ($SubscriptionId, $SCEPmanResourceGroup, $SCEPmanAppServiceName, $CertMasterResourceGroup, $CertMasterAppServiceName, $servicePrincipals, $DeploymentSlotName, $DeploymentSlots) {
    $existingTableStorageEndpointSettingSc = GetSCEPmanStorageAccountConfig -SCEPmanResourceGroup $SCEPmanResourceGroup -SCEPmanAppServiceName $SCEPmanAppServiceName -DeploymentSlotName $DeploymentSlotName
    $existingTableStorageEndpointSettingCm = az webapp config appsettings list --name $CertMasterAppServiceName --resource-group $CertMasterResourceGroup --query "[?name=='AppConfig:AzureStorage:TableStorageEndpoint'].value | [0]"
    $storageAccountTableEndpoint = $null

    if(![string]::IsNullOrEmpty($existingTableStorageEndpointSettingSc)) {
        if(![string]::IsNullOrEmpty($existingTableStorageEndpointSettingCm) -and $existingTableStorageEndpointSettingSc -ne $existingTableStorageEndpointSettingCm) {
            Write-Error "Inconsistency: SCEPman($SCEPmanAppServiceName) and CertMaster($CertMasterAppServiceName) have different storage accounts configured"
            throw "Inconsistency: SCEPman($SCEPmanAppServiceName) and CertMaster($CertMasterAppServiceName) have different storage accounts configured"
        }
        $storageAccountTableEndpoint = $existingTableStorageEndpointSettingSc.Trim('"')
    }

    if([string]::IsNullOrEmpty($storageAccountTableEndpoint) -and ![string]::IsNullOrEmpty($existingTableStorageEndpointSettingCm)) {
        $storageAccountTableEndpoint = $existingTableStorageEndpointSettingCm.Trim('"')
    }

    if([string]::IsNullOrEmpty($storageAccountTableEndpoint)) {
        Write-Information "Getting storage account"
        $ScStorageAccount = CreateScStorageAccount -SubscriptionId $SubscriptionId -ResourceGroup $SCEPmanResourceGroup -servicePrincipals $servicePrincipals
        $storageAccountTableEndpoint = $($ScStorageAccount.primaryEndpoints.table)
    } else {
        Write-Verbose 'Storage account table endpoint found in app settings'

        $ScStorageAccount = GetExistingStorageAccount -dataTableEndpoint $storageAccountTableEndpoint
        if ($null -eq $ScStorageAccount) {
            Write-Warning "Data Table endpoint $storageAccountTableEndpoint is configured in either SCEPman or Certificate Master, but no such storage account could be found"

            $ScStorageAccount = CreateScStorageAccount -SubscriptionId $SubscriptionId -ResourceGroup $SCEPmanResourceGroup -servicePrincipals $servicePrincipals
            $storageAccountTableEndpoint = $($ScStorageAccount.primaryEndpoints.table)
        } else {
            Write-Verbose "Found existing storage account $($ScStorageAccount.Name)"
            SetStorageAccountPermissions -SubscriptionId $SubscriptionId -ScStorageAccount $ScStorageAccount -servicePrincipals $servicePrincipals
        }
    }

    Write-Verbose "Configuring table storage endpoints in SCEPman, SCEPman's deployment slots (if any), and CertMaster"
    $null = az webapp config appsettings set --name $CertMasterAppServiceName --resource-group $CertMasterResourceGroup --settings AppConfig:AzureStorage:TableStorageEndpoint=$storageAccountTableEndpoint
    $null = az webapp config appsettings set --name $SCEPmanAppServiceName --resource-group $SCEPmanResourceGroup --settings AppConfig:CertificateStorage:TableStorageEndpoint=$storageAccountTableEndpoint
    ForEach($tempDeploymentSlot in $DeploymentSlots) {
        $null = az webapp config appsettings set --name $SCEPmanAppServiceName --resource-group $SCEPmanResourceGroup --settings AppConfig:CertificateStorage:TableStorageEndpoint=$storageAccountTableEndpoint --slot $tempDeploymentSlot
    }
}
