
function VerifyStorageAccountDoesNotExist ($ResourceGroup) {
    $storageaccounts = Convert-LinesToObject -lines $(az graph query -q "Resources | where type == 'microsoft.storage/storageaccounts' and resourceGroup == '$ResourceGroup' | project name, resourceGroup, primaryEndpoints = properties.primaryEndpoints, subscriptionId, location")
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
        Write-Information "Unable to find an existing storage account"
        return $null
    }
}

function GetExistingStorageAccount ($dataTableEndpoint) {
    $storageAccounts = Convert-LinesToObject -lines $(az graph query -q "Resources | where type == 'microsoft.storage/storageaccounts' and properties.primaryEndpoints.table startswith '$($dataTableEndpoint.TrimEnd('/'))' | project name, resourceGroup, primaryEndpoints = properties.primaryEndpoints, subscriptionId, location")
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
    Write-Information "Setting permissions in storage account for $($servicePrincipals.Count) App Service identities"

    if ($null -ne $ScStorageAccount.SubscriptionId) {
        $SubscriptionId = $ScStorageAccount.SubscriptionId
    }

    $SAScope = "/subscriptions/$SubscriptionId/resourceGroups/$($ScStorageAccount.resourceGroup)/providers/Microsoft.Storage/storageAccounts/$($ScStorageAccount.name)"
    Write-Debug "Storage Account Scope: $SAScope"
    ForEach($tempServicePrincipal in $servicePrincipals) {
        Write-Information "Setting Storage account permission for principal id $tempServicePrincipal"
        $null = Invoke-Az @("role", "assignment", "create", "--role", "Storage Table Data Contributor", "--assignee-object-id", $tempServicePrincipal, "--assignee-principal-type", "ServicePrincipal", "--scope", $SAScope)
    }
}

function CreateScStorageAccount ($SubscriptionId, $ResourceGroup, $servicePrincipals) {
    $ScStorageAccount = VerifyStorageAccountDoesNotExist -ResourceGroup $ResourceGroup
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
        $ScStorageAccount = Convert-LinesToObject -lines $(az storage account create --name $storageAccountName --resource-group $ResourceGroup --sku 'Standard_LRS' --kind 'StorageV2' --access-tier 'Hot' --allow-blob-public-access $true --allow-cross-tenant-replication $false --allow-shared-key-access $false --enable-nfs-v3 $false --min-tls-version 'TLS1_2' --publish-internet-endpoints $false --publish-microsoft-endpoints $false --routing-choice 'MicrosoftRouting' --https-only $true --only-show-errors)
        if($null -eq $ScStorageAccount) {
            Write-Error 'Storage account not found and we are unable to create one. Please check logs for more details before re-running the script'
            throw 'Storage account not found and we are unable to create one. Please check logs for more details before re-running the script'
        }
        Write-Information "Storage account $storageAccountName created"
    }

    SetStorageAccountPermissions -SubscriptionId $SubscriptionId -ScStorageAccount $ScStorageAccount -servicePrincipals $servicePrincipals

    return $ScStorageAccount
}

function Grant-VnetAccessToStorageAccount ($ScStorageAccount, $SubnetId, $SubscriptionId) {
    Write-Verbose "Adding VNET access to storage account $($ScStorageAccount.name) from Subnet $SubnetId"
    $ScStorageAccountJson = Invoke-Az @("storage", "account", "network-rule", "add", "--account-name", $ScStorageAccount.name, "--subnet", $SubnetId, "--subscription", $SubscriptionId)
    $ScStorageAccount = Convert-LinesToObject -lines $ScStorageAccountJson
    if ($ScStorageAccount.networkRuleSet.defaultAction -ieq "Deny" -and $ScStorageAccount.publicNetworkAccess -ine "Enabled") {
        Write-Information "Storage Account $($ScStorageAccount.name) is configured to deny all traffic from public networks. Allowing traffic from configured VNETs"
        $null = Invoke-Az @("storage", "account", "update", "--name", $ScStorageAccount.name, "--public-network-access", "Enabled", "--subscription", $SubscriptionId)
    }
}

function GetSCEPmanStorageAccountConfig( $SCEPmanResourceGroup, $SCEPmanAppServiceName, $DeploymentSlotName) {
    return ReadAppSetting -ResourceGroup $SCEPmanResourceGroup -AppServiceName $SCEPmanAppServiceName -SettingName "AppConfig:CertificateStorage:TableStorageEndpoint" -DeploymentSlotName $DeploymentSlotName
}

function Set-TableStorageEndpointsInScAndCmAppSettings {
    [CmdletBinding(SupportsShouldProcess=$true)]
    param (
        [Parameter(Mandatory=$true)]        [string]$SubscriptionId,
        [Parameter(Mandatory=$true)]        [string]$SCEPmanResourceGroup,
        [Parameter(Mandatory=$true)]        [string]$SCEPmanAppServiceName,
        [Parameter(Mandatory=$false)]        [string]$CertMasterResourceGroup,
        [Parameter(Mandatory=$false)]        [string]$CertMasterAppServiceName,
        [Parameter(Mandatory=$true)]        [System.Collections.IList]$servicePrincipals,
        [Parameter(Mandatory=$false)]        [string]$DeploymentSlotName,
        [Parameter(Mandatory=$false)]        [System.Collections.IList]$DeploymentSlots
    )

    $storageAccountTableEndpoint = $null
    $existingTableStorageEndpointSettingSc = GetSCEPmanStorageAccountConfig -SCEPmanResourceGroup $SCEPmanResourceGroup -SCEPmanAppServiceName $SCEPmanAppServiceName -DeploymentSlotName $DeploymentSlotName
    if(![string]::IsNullOrEmpty($existingTableStorageEndpointSettingSc)) {
        $storageAccountTableEndpoint = $existingTableStorageEndpointSettingSc
        Write-Verbose "Found existing storage account table endpoint in SCEPman's app settings"
    }

    if (![string]::IsNullOrEmpty($CertMasterAppServiceName)) {
        $existingTableStorageEndpointSettingCm = ReadAppSetting -ResourceGroup $CertMasterResourceGroup -AppServiceName $CertMasterAppServiceName -SettingName "AppConfig:AzureStorage:TableStorageEndpoint"

        if(![string]::IsNullOrEmpty($existingTableStorageEndpointSettingSc) -and ![string]::IsNullOrEmpty($existingTableStorageEndpointSettingCm) -and $existingTableStorageEndpointSettingSc -ne $existingTableStorageEndpointSettingCm) {
            Write-Error "Inconsistency: SCEPman($SCEPmanAppServiceName) and CertMaster($CertMasterAppServiceName) have different storage accounts configured"
            throw "Inconsistency: SCEPman($SCEPmanAppServiceName) and CertMaster($CertMasterAppServiceName) have different storage accounts configured"
        }

        if([string]::IsNullOrEmpty($storageAccountTableEndpoint) -and ![string]::IsNullOrEmpty($existingTableStorageEndpointSettingCm)) {
            $storageAccountTableEndpoint = $existingTableStorageEndpointSettingCm
            Write-Verbose "Found existing storage account table endpoint in CertMaster's app settings"
        }
    }

    if([string]::IsNullOrEmpty($storageAccountTableEndpoint)) {
        Write-Warning "No storage account found. This is only expected if you upgrade from SCEPman 1.x"
        Write-Information "Creating storage account"
        if ($PSCmdlet.ShouldProcess($storageAccountTableEndpoint, "Create storage account")) {
            $ScStorageAccount = CreateScStorageAccount -SubscriptionId $SubscriptionId -ResourceGroup $SCEPmanResourceGroup -servicePrincipals $servicePrincipals
            $storageAccountTableEndpoint = $($ScStorageAccount.primaryEndpoints.table)
        }
    } else {
        Write-Verbose 'Storage account table endpoint found in app settings'

        $ScStorageAccount = GetExistingStorageAccount -dataTableEndpoint $storageAccountTableEndpoint
        if ($null -eq $ScStorageAccount) {
            Write-Warning "Data Table endpoint $storageAccountTableEndpoint is configured in either SCEPman or Certificate Master, but no such storage account could be found"

            if ($PSCmdlet.ShouldProcess($storageAccountTableEndpoint, "Create storage account")) {
                $ScStorageAccount = CreateScStorageAccount -SubscriptionId $SubscriptionId -ResourceGroup $SCEPmanResourceGroup -servicePrincipals $servicePrincipals
                $storageAccountTableEndpoint = $($ScStorageAccount.primaryEndpoints.table)
            }
        } else {
            Write-Verbose "Found existing storage account $($ScStorageAccount.Name)"
            if ($PSCmdlet.ShouldProcess($storageAccountTableEndpoint, "Set storage account permissions for service principals")) {
                SetStorageAccountPermissions -SubscriptionId $SubscriptionId -ScStorageAccount $ScStorageAccount -servicePrincipals $servicePrincipals
            }
        }
    }

    Write-Verbose "Configuring table storage endpoints in SCEPman, SCEPman's deployment slots (if any), and CertMaster"
    if (![string]::IsNullOrEmpty($CertMasterAppServiceName)) {
        $storageSettingForCm = @(
            @{name='AppConfig:AzureStorage:TableStorageEndpoint'; value=$storageAccountTableEndpoint}
        )
        Write-Debug "Setting storage account table endpoint in CertMaster"
        if ($PSCmdlet.ShouldProcess($CertMasterAppServiceName, "Setting storage account table endpoint in CertMaster")) {
            SetAppSettings -AppServiceName $CertMasterAppServiceName -ResourceGroup $CertMasterResourceGroup -Settings $storageSettingForCm
        }
    }

    $storageSettingForSm = @(
        @{name='AppConfig:CertificateStorage:TableStorageEndpoint'; value=$storageAccountTableEndpoint}
    )
    ForEach($tempDeploymentSlot in $DeploymentSlots) {
        if ($PSCmdlet.ShouldProcess("$SCEPmanAppServiceName $tempDeploymentSlot", "Setting storage account table endpoint in SCEPman")) {
            SetAppSettings -AppServiceName $SCEPmanAppServiceName -ResourceGroup $SCEPmanResourceGroup -Settings $storageSettingForSm -Slot $tempDeploymentSlot
        }
    }
}
