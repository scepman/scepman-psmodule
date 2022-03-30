# for testing
#$env:SCEPMAN_APP_SERVICE_NAME = "as-scepman-deploytest"
#$env:CERTMASTER_APP_SERVICE_NAME = "aleen-as-certmaster-askjvljweklraesr"
#$env:SCEPMAN_RESOURCE_GROUP = "rg-SCEPman" # Optional

$SCEPmanAppServiceName = $env:SCEPMAN_APP_SERVICE_NAME
$CertMasterAppServiceName = $env:CERTMASTER_APP_SERVICE_NAME
$SCEPmanResourceGroup = $env:SCEPMAN_RESOURCE_GROUP
$SubscriptionId = $env:SUBSCRIPTION_ID

# Some hard-coded definitions
$MSGraphAppId = "00000003-0000-0000-c000-000000000000"
$MSGraphDirectoryReadAllPermission = "7ab1d382-f21e-4acd-a863-ba3e13f7da61"
$MSGraphDeviceManagementReadPermission = "2f51be20-0bb4-4fed-bf7b-db946066c75e"
$MSGraphUserReadPermission = "e1fe6dd8-ba31-4d61-89e7-88639da4683d"

# "0000000a-0000-0000-c000-000000000000" # Service Principal App Id of Intune, not required here
$IntuneAppId = "c161e42e-d4df-4a3d-9b42-e7a3c31f59d4" # Well-known App ID of the Intune API
$IntuneSCEPChallengePermission = "39d724e8-6a34-4930-9a36-364082c35716"

$MAX_RETRY_COUNT = 4  # for some operations, retry a couple of times

$azureADAppNameForSCEPman = 'SCEPman-api' #Azure AD app name for SCEPman
$azureADAppNameForCertMaster = 'SCEPman-CertMaster' #Azure AD app name for certmaster

# JSON defining App Role that CertMaster uses to authenticate against SCEPman
$ScepmanManifest = '[{
        \"allowedMemberTypes\": [
          \"Application\"
        ],
        \"description\": \"Request certificates via the raw CSR API\",
        \"displayName\": \"CSR Requesters\",
        \"isEnabled\": \"true\",
        \"value\": \"CSR.Request\"
    }]'.Replace("`r", [String]::Empty).Replace("`n", [String]::Empty)

# JSON defining App Role that User can have to when authenticating against CertMaster
$CertmasterManifest = '[{
    \"allowedMemberTypes\": [
      \"User\"
    ],
    \"description\": \"Full access to all SCEPman CertMaster functions like requesting and managing certificates\",
    \"displayName\": \"Full Admin\",
    \"isEnabled\": \"true\",
    \"value\": \"Admin.Full\"
}]'.Replace("`r", [String]::Empty).Replace("`n", [String]::Empty)


function ConvertLinesToObject($lines) {
    if($null -eq $lines) {
        return $null
    }
    $linesJson = [System.String]::Concat($lines)
    return ConvertFrom-Json $linesJson
}

function CheckAzOutput($azOutput) {
    foreach ($outputElement in $azOutput) {
        if ($null -ne $outputElement) {
            if ($outputElement.GetType() -eq [System.Management.Automation.ErrorRecord]) {
                if ($outputElement.ToString().Contains("Permission being assigned already exists on the object")) {  # TODO: Does this work in non-English environments?
                    Write-Information "Permission is already assigned when executing $azCommand"
                } elseif ($outputElement.ToString().StartsWith("WARNING")) {
                    if ($outputElement.ToString().StartsWith("WARNING: The underlying Active Directory Graph API will be replaced by Microsoft Graph API")) {
                        # Ignore, we know that
                    } else {
                        Write-Warning $outputElement.ToString()
                    }
                } else {
                    Write-Error $outputElement
                    throw $outputElement
                }
            } else {
                Write-Output $outputElement # add to return value of this function
            }
        }
    }
}

function AzLogin {
        # Check whether az is available
    $azCommand = Get-Command az 2>&1
    if ($azCommand.GetType() -eq [System.Management.Automation.ErrorRecord]) {
        if ($azCommand.CategoryInfo.Reason -eq "CommandNotFoundException") {
            $errorMessage = "Azure CLI (az) is not installed, but required. Please use the Azure Cloud Shell or install Azure CLI as described here: https://docs.microsoft.com/en-us/cli/azure/install-azure-cli"
            Write-Error $errorMessage
            throw $errorMessage
        }
        else {
            Write-Error "Unknown error checking for az"
            throw $azCommand
        }
    }

        # check whether already logged in
    $account = az account show 2>&1
    if ($account.GetType() -eq [System.Management.Automation.ErrorRecord]) {
        if ($account.ToString().Contains("az login")) {
            Write-Host "Not logged in to az yet. Please log in."
            $null = az login # TODO: Check whether the login worked
        }
        else {
            Write-Error "Error $account while trying to use az" # possibly az not installed?
            throw $account
        }
    } else {
        $accountInfo = ConvertLinesToObject($account)
        Write-Information "Logged in to az as $($accountInfo.user.name)"
    }
}

function GetSubscriptionDetailsUsingSCEPmanAppName($subscriptions) {
    $correctSubscription = $null
    Write-Information "Finding correct subscription"
    $scWebAppsAcrossAllAccessibleSubscriptions = ConvertLinesToObject -lines $(az graph query -q "Resources | where type == 'microsoft.web/sites' and name == '$SCEPmanAppServiceName' | project name, subscriptionId" -s $subscriptions.id)
    if($scWebAppsAcrossAllAccessibleSubscriptions.count -eq 1) {
        $correctSubscription = $subscriptions | Where-Object { $_.id -eq $scWebAppsAcrossAllAccessibleSubscriptions.data[0].subscriptionId }
    }
    if($null -eq $correctSubscription) {
        $errorMessage = "We are unable to determine the correct subscription. Please start over"
        Write-Error $errorMessage
        throw $errorMessage
    }
    return $correctSubscription
}

function GetSubscriptionDetails {
  $potentialSubscription = $null
  $subscriptions = ConvertLinesToObject -lines $(az account list)
  if($false -eq [String]::IsNullOrWhiteSpace($SubscriptionId)) {
    $potentialSubscription = $subscriptions | Where-Object { $_.id -eq $SubscriptionId }
    if($null -eq $potentialSubscription) {
        Write-Warning "We are unable to find the subscription with id $SubscriptionId"
        throw "We are unable to find the subscription with id $SubscriptionId"
    }
  }
  if($null -eq $potentialSubscription) {
    if($subscriptions.count -gt 1){
        if($SearchAllSubscriptions.IsPresent) {
            Write-Information "User pre-selected to search all subscriptions"
            $selection = 0
        } else {
            Write-Host "Multiple subscriptions found! Select a subscription where the SCPEman is installed or press '0' to search across all of the subscriptions"
            Write-Host "0: Search All Subscriptions | Press '0'"
            for($i = 0; $i -lt $subscriptions.count; $i++){
                Write-Host "$($i + 1): $($subscriptions[$i].name) | Subscription Id: $($subscriptions[$i].id) | Press '$($i + 1)' to use this subscription"
            }
            $selection = Read-Host -Prompt "Please enter your choice and hit enter"
        }
        $subscriptionGuid = [System.Guid]::empty
        if ([System.Guid]::TryParse($selection, [System.Management.Automation.PSReference]$subscriptionGuid)) {
            $potentialSubscription = $subscriptions | Where-Object { $_.id -eq $selection }
        } elseif(0 -eq $selection) {
            $potentialSubscription = GetSubscriptionDetailsUsingSCEPmanAppName -subscriptions $subscriptions
        } else {
            $potentialSubscription = $subscriptions[$($selection - 1)]
        }
        if($null -eq $potentialSubscription) {
            Write-Error "We couldn't find the selected subscription. Please try to re-run the script"
            throw "We couldn't find the selected subscription. Please try to re-run the script"
        }
      } else {
        $potentialSubscription = $subscriptions[0]
      }
  }
  $null = az account set --subscription $($potentialSubscription.id)
  return $potentialSubscription
}

# It is intended to use for az cli add permissions and az cli add permissions admin
# $azCommand - The command to execute.
#
function ExecuteAzCommandRobustly($azCommand, $principalId = $null, $appRoleId = $null) {
  $azErrorCode = 1234 # A number not null
  $retryCount = 0
  while ($azErrorCode -ne 0 -and $retryCount -le $MAX_RETRY_COUNT) {
    $lastAzOutput = Invoke-Expression $azCommand 2>&1 # the output is often empty in case of error :-(. az just writes to the console then
    $azErrorCode = $LastExitCode
    try {
        $lastAzOutput = CheckAzOutput($lastAzOutput)
        if($null -ne $appRoleId -and $azErrorCode -eq 0) {
            $appRoleAssignments = ConvertLinesToObject -lines $(az rest --method get --url "https://graph.microsoft.com/v1.0/servicePrincipals/$principalId/appRoleAssignments")
            $grantedPermission = $appRoleAssignments.value | Where-Object { $_.appRoleId -eq $appRoleId }
            if ($null -eq $grantedPermission) {
                $azErrorCode = 999 # A number not 0
            }
        }
    }
    catch {
        Write-Warning $_
        $azErrorCode = 654  # a number not 0
    }
    if ($azErrorCode -ne 0) {
      ++$retryCount
      Write-Verbose "Retry $retryCount for $azCommand"
      Start-Sleep $retryCount # Sleep for some seconds, as the grant sometimes only works after some time
    }
  }
  if ($azErrorCode -ne 0 ) {
    Write-Error "Error $azErrorCode when executing $azCommand : $($lastAzOutput.ToString())"
    throw "Error $azErrorCode when executing $azCommand : $($lastAzOutput.ToString())"
  }
  else {
    return $lastAzOutput
  }
}

function GetResourceGroup {
  if ([String]::IsNullOrWhiteSpace($SCEPmanResourceGroup)) {
    # No resource group given, search for it now
    $scWebAppsInTheSubscription = ConvertLinesToObject -lines $(az graph query -q "Resources | where type == 'microsoft.web/sites' and name == '$SCEPmanAppServiceName' | project name, resourceGroup")
    if($null -ne $scWebAppsInTheSubscription -and $($scWebAppsInTheSubscription.count) -eq 1) {
        return $scWebAppsInTheSubscription.data[0].resourceGroup
    }
    Write-Error "Unable to determine the resource group. This generally happens when a wrong name is entered for the SCEPman web app!"
    throw "Unable to determine the resource group. This generally happens when a wrong name is entered for the SCEPman web app!"
  }
  return $SCEPmanResourceGroup;
}


function GetCertMasterAppServiceName {
    if ([String]::IsNullOrWhiteSpace($CertMasterAppServiceName)) {

    #       Criteria:
    #       - Only two App Services in SCEPman's resource group. One is SCEPman, the other the CertMaster candidate
    #       - Configuration value AppConfig:SCEPman:URL must be present, then it must be a CertMaster
    #       - In a default installation, the URL must contain SCEPman's app service name. We require this.

      $strangeCertMasterFound = $false

      $rgwebapps =  ConvertLinesToObject -lines $(az graph query -q "Resources | where type == 'microsoft.web/sites' and resourceGroup == '$SCEPmanResourceGroup' and name !~ '$SCEPmanAppServiceName' | project name")
      Write-Information "$($rgwebapps.count + 1) web apps found in the resource group $SCEPmanResourceGroup. We are finding if the CertMaster app is already created"
      if($rgwebapps.count -gt 0) {
        ForEach($potentialcmwebapp in $rgwebapps.data) {
            $scepmanurlsettingcount = az webapp config appsettings list --name $potentialcmwebapp.name --resource-group $SCEPmanResourceGroup --query "[?name=='AppConfig:SCEPman:URL'].value | length(@)"
            if($scepmanurlsettingcount -eq 1) {
                $scepmanUrl = az webapp config appsettings list --name $potentialcmwebapp.name --resource-group $SCEPmanResourceGroup --query "[?name=='AppConfig:SCEPman:URL'].value | [0]"
                $hascorrectscepmanurl = $scepmanUrl.ToUpperInvariant().Contains($SCEPmanAppServiceName.ToUpperInvariant())  # this works for deployment slots, too
                if($hascorrectscepmanurl -eq $true) {
                    Write-Information "Certificate Master web app $($potentialcmwebapp.name) found."
                    $CertMasterAppServiceName = $potentialcmwebapp.name
                    return $potentialcmwebapp.name
                } else {
                    Write-Information "Certificate Master web app $($potentialcmwebapp.name) found, but its setting AppConfig:SCEPman:URL is $scepmanURL, which we could not identify with the SCEPman app service. It may or may not be the correct Certificate Master and we ignore it."
                    $strangeCertMasterFound = $true
                }
            }
        }
      }
      if ($strangeCertMasterFound) {
          Write-Warning "There is at least one Certificate Master App Service in resource group $SCEPmanResourceGroup, but we are not sure whether it belongs to SCEPman $SCEPmanAppServiceName."
      }

      Write-Warning "Unable to determine the Certificate Master app service name"
      return $null
    }
    return $CertMasterAppServiceName;
}

function CreateCertMasterAppService {
  $CertMasterAppServiceName = GetCertMasterAppServiceName
  $CreateCertMasterAppService = $false

  if($null -eq $CertMasterAppServiceName) {
    $CreateCertMasterAppService =  $true
  } else {
    # This can happen if user uses environment variable to set the CertMaster app service name
    $CertMasterWebApps = ConvertLinesToObject -lines $(az graph query -q "Resources | where type == 'microsoft.web/sites' and resourceGroup == '$SCEPmanResourceGroup' and name =~ '$CertMasterAppServiceName' | project name")
    if(0 -eq $CertMasterWebApps.count) {
        $CreateCertMasterAppService =  $true
    }
  }

  $scwebapp = ConvertLinesToObject -lines $(az graph query -q "Resources | where type == 'microsoft.web/sites' and resourceGroup == '$SCEPmanResourceGroup' and name =~ '$SCEPmanAppServiceName'")

  if($null -eq $CertMasterAppServiceName) {
    $CertMasterAppServiceName = $scwebapp.data.name
    if ($CertMasterAppServiceName.Length -gt 57) {
      $CertMasterAppServiceName = $CertMasterAppServiceName.Substring(0,57)
    }

    $CertMasterAppServiceName += "-cm"
    $potentialCertMasterAppServiceName = Read-Host "CertMaster web app not found. Please hit enter now if you want to create the app with name $CertMasterAppServiceName or enter the name of your choice, and then hit enter"

    if($potentialCertMasterAppServiceName) {
        $CertMasterAppServiceName = $potentialCertMasterAppServiceName
    }
  }

  if ($true -eq $CreateCertMasterAppService) {

    Write-Information "User selected to create the app with the name $CertMasterAppServiceName"

    $null = az webapp create --resource-group $SCEPmanResourceGroup --plan $scwebapp.data.properties.serverFarmId --name $CertMasterAppServiceName --assign-identity [system] --% --runtime "DOTNET|5.0"
    Write-Information "CertMaster web app $CertMasterAppServiceName created"

    # Do all the configuration that the ARM template does normally
    $SCEPmanHostname = $scwebapp.data.properties.defaultHostName
    if ($null -ne $DeploymentSlotName) {
        $selectedSlot = ConvertLinesToObject -lines $(az graph query -q "Resources | where type == 'microsoft.web/sites/slots' and resourceGroup == '$SCEPmanResourceGroup' and name =~ '$SCEPmanAppServiceName/$DeploymentSlotName'")
        $SCEPmanHostname = $selectedSlot.data.properties.defaultHostName
    }
    $CertmasterAppSettings = @{
      WEBSITE_RUN_FROM_PACKAGE = "https://raw.githubusercontent.com/scepman/install/master/dist-certmaster/CertMaster-Artifacts.zip";
      "AppConfig:AuthConfig:TenantId" = $subscription.tenantId;
      "AppConfig:SCEPman:URL" = "https://$SCEPmanHostname/";
    } | ConvertTo-Json -Compress
    $CertMasterAppSettings = $CertmasterAppSettings.Replace('"', '\"')

    Write-Verbose 'Configuring CertMaster web app settings'
    $null = az webapp config set --name $CertMasterAppServiceName --resource-group $SCEPmanResourceGroup --use-32bit-worker-process $false --ftps-state 'Disabled' --always-on $true
    $null = az webapp update --name $CertMasterAppServiceName --resource-group $SCEPmanResourceGroup --https-only $true
    $null = az webapp config appsettings set --name $CertMasterAppServiceName --resource-group $SCEPmanResourceGroup --settings $CertMasterAppSettings
  }

  return $CertMasterAppServiceName
}

function GetStorageAccount {
    $storageaccounts = ConvertLinesToObject -lines $(az graph query -q "Resources | where type == 'microsoft.storage/storageaccounts' and resourceGroup == '$SCEPmanResourceGroup' | project name, primaryEndpoints = properties.primaryEndpoints")
    if($storageaccounts.count -gt 0) {
        $potentialStorageAccountName = Read-Host "We have found one or more existing storage accounts in the resource group $SCEPmanResourceGroup. Please hit enter now if you still want to create a new storage account or enter the name of the storage account you would like to use, and then hit enter"
        if(!$potentialStorageAccountName) {
            Write-Information "User selected to create a new storage account"
            return $null
        } else {
            $potentialStorageAccount = $storageaccounts.data | Where-Object { $_.name -eq $potentialStorageAccountName }
            if($null -eq $potentialStorageAccount) {
                Write-Error "We couldn't find a storage account with name $potentialStorageAccountName. Please try to re-run the script"
                throw "We couldn't find a storage account with name $potentialStorageAccountName. Please try to re-run the script"
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
    $storageAccounts = ConvertLinesToObject -lines $(az graph query -q "Resources | where type == 'microsoft.storage/storageaccounts' and properties.primaryEndpoints.table startswith '$($dataTableEndpoint.TrimEnd('/'))' | project name, primaryEndpoints = properties.primaryEndpoints")
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

function SetStorageAccountPermissions ($ScStorageAccount) {
    Write-Information "Setting permissions in storage account for SCEPman, SCEPman's deployment slots (if any), and CertMaster"

    $SAScope = "/subscriptions/$($subscription.id)/resourceGroups/$SCEPmanResourceGroup/providers/Microsoft.Storage/storageAccounts/$($ScStorageAccount.name)"
    Write-Debug "Storage Account Scope: $SAScope"
    $null = CheckAzOutput(az role assignment create --role 'Storage Table Data Contributor' --assignee-object-id $serviceprincipalcm.principalId --assignee-principal-type 'ServicePrincipal' --scope $SAScope 2>&1)
    if ($null -ne $serviceprincipalsc) {
        $null = CheckAzOutput(az role assignment create --role 'Storage Table Data Contributor' --assignee-object-id $serviceprincipalsc.principalId --assignee-principal-type 'ServicePrincipal' --scope $SAScope 2>&1)
    }
    if($true -eq $scHasDeploymentSlots) {
        ForEach($tempServicePrincipal in $serviceprincipalOfScDeploymentSlots) {
            Write-Verbose "Setting Storage account permission for deployment slot with principal id $tempServicePrincial"
            $null = CheckAzOutput(az role assignment create --role 'Storage Table Data Contributor' --assignee-object-id $tempServicePrincipal.principalId --assignee-principal-type 'ServicePrincipal' --scope $SAScope 2>&1)
        }
    }
}

function CreateScStorageAccount {
    $ScStorageAccount = GetStorageAccount
    if($null -eq $ScStorageAccount) {
        Write-Information 'Storage account not found. We will create one now'
        $storageAccountName = $SCEPmanResourceGroup.ToLower() -replace '[^a-z0-9]',''
        if($storageAccountName.Length -gt 19) {
            $storageAccountName = $storageAccountName.Substring(0,19)
        }
        $storageAccountName = "stg$($storageAccountName)cm"
        $potentialStorageAccountName = Read-Host "Please hit enter now if you want to create the storage account with name $storageAccountName or enter the name of your choice, and then hit enter"
        if($potentialStorageAccountName) {
            $storageAccountName = $potentialStorageAccountName
        }
        $ScStorageAccount = ConvertLinesToObject -lines $(az storage account create --name $storageAccountName --resource-group $SCEPmanResourceGroup --sku 'Standard_LRS' --kind 'StorageV2' --access-tier 'Hot' --allow-blob-public-access $true --allow-cross-tenant-replication $false --allow-shared-key-access $false --enable-nfs-v3 $false --min-tls-version 'TLS1_2' --publish-internet-endpoints $false --publish-microsoft-endpoints $false --routing-choice 'MicrosoftRouting' --https-only $true --only-show-errors)
        if($null -eq $ScStorageAccount) {
            Write-Error 'Storage account not found and we are unable to create one. Please check logs for more details before re-running the script'
            throw 'Storage account not found and we are unable to create one. Please check logs for more details before re-running the script'
        }
        Write-Information "Storage account $storageAccountName created"
    }

    SetStorageAccountPermissions -ScStorageAccount $ScStorageAccount

    return $ScStorageAccount
}

function SetTableStorageEndpointsInScAndCmAppSettings {

    if ($null -eq $DeploymentSlotName) {
        $existingTableStorageEndpointSettingSc = az webapp config appsettings list --name $SCEPmanAppServiceName --resource-group $SCEPmanResourceGroup --query "[?name=='AppConfig:CertificateStorage:TableStorageEndpoint'].value | [0]"
    } else {
        $existingTableStorageEndpointSettingSc = az webapp config appsettings list --name $SCEPmanAppServiceName --resource-group $SCEPmanResourceGroup --query "[?name=='AppConfig:CertificateStorage:TableStorageEndpoint'].value | [0]" --slot $DeploymentSlotName
    }
    $existingTableStorageEndpointSettingCm = az webapp config appsettings list --name $CertMasterAppServiceName --resource-group $SCEPmanResourceGroup --query "[?name=='AppConfig:AzureStorage:TableStorageEndpoint'].value | [0]"
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
        $ScStorageAccount = CreateScStorageAccount
        $storageAccountTableEndpoint = $($ScStorageAccount.primaryEndpoints.table)
    } else {
        Write-Verbose 'Storage account table endpoint found in app settings'

        $ScStorageAccount = GetExistingStorageAccount -dataTableEndpoint $storageAccountTableEndpoint
        if ($null -eq $ScStorageAccount) {
            Write-Warning "Data Table endpoint $storageAccountTableEndpoint is configured in either SCEPman or Certificate Master, but no such storage account could be found"

            $ScStorageAccount = CreateScStorageAccount
            $storageAccountTableEndpoint = $($ScStorageAccount.primaryEndpoints.table)
        } else {
            Write-Verbose "Found existing storage account $($ScStorageAccount.Name)"
            SetStorageAccountPermissions -ScStorageAccount $ScStorageAccount
        }
    }

    Write-Verbose "Configuring table storage endpoints in SCEPman, SCEPman's deployment slots (if any), and CertMaster"
    $null = az webapp config appsettings set --name $CertMasterAppServiceName --resource-group $SCEPmanResourceGroup --settings AppConfig:AzureStorage:TableStorageEndpoint=$storageAccountTableEndpoint
    $null = az webapp config appsettings set --name $SCEPmanAppServiceName --resource-group $SCEPmanResourceGroup --settings AppConfig:CertificateStorage:TableStorageEndpoint=$storageAccountTableEndpoint
    if($true -eq $scHasDeploymentSlots) {
        ForEach($tempDeploymentSlot in $deploymentSlotsSc) {
            $null = az webapp config appsettings set --name $SCEPmanAppServiceName --resource-group $SCEPmanResourceGroup --settings AppConfig:CertificateStorage:TableStorageEndpoint=$storageAccountTableEndpoint --slot $tempDeploymentSlot
        }
    }
}

function GetDeploymentSlots($appServiceNameParam, $resourceGroupParam) {
    $deploymentSlots = ConvertLinesToObject -lines $(az webapp deployment slot list --name $SCEPmanAppServiceName --resource-group $SCEPmanResourceGroup --query '[].name')
    return $deploymentSlots
}

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

function CreateServicePrincipal($appId) {
    $sp = ConvertLinesToObject -lines $(az ad sp list --filter "appId eq '$appId'" --query "[0]" --only-show-errors)
    if($null -eq $sp) {
        #App Registration SP doesn't exist.
        return ConvertLinesToObject -lines $(ExecuteAzCommandRobustly -azCommand "az ad sp create --id $appId")
    }
    else {
        return $sp
    }
}

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

<#
 .Synopsis
  Adds the required configuration to SCEPman (https://scepman.com/) right after installing or updating to a 2.x version.

 .Parameter SCEPmanAppServiceName
  The name of the SCEPman App Service

 .Parameter CertMasterAppServiceName
  The name of the SCEPman Certificate Master App Service

 .Parameter SCEPmanResourceGroup
  The Azure resource group hosting the SCEPman App Service

 .Example
   # Configure SCEPman in your tenant where the app service name is as-scepman
   Configure-SCEPman -SCEPmanAppServiceName as-scepman

 .Example
   # Configure SCEPman and ask interactively for the app service
   Configure-SCEPman
#>
function Complete-SCEPmanInstallation
{
    [CmdletBinding()]
    param($SCEPmanAppServiceName, $CertMasterAppServiceName, $SCEPmanResourceGroup, [switch]$SearchAllSubscriptions, $DeploymentSlotName)

    if ([String]::IsNullOrWhiteSpace($SCEPmanAppServiceName)) {
        $SCEPmanAppServiceName = Read-Host "Please enter the SCEPman app service name"
    }

    Write-Information "Installing az resource graph extension"
    az extension add --name resource-graph --only-show-errors

    Write-Information "Configuring SCEPman and CertMaster"

    Write-Information "Logging in to az"
    AzLogin

    Write-Information "Getting subscription details"
    $subscription = GetSubscriptionDetails
    Write-Information "Subscription is set to $($subscription.name)"

    Write-Information "Setting resource group"
    $SCEPmanResourceGroup = GetResourceGroup

    Write-Information "Getting SCEPman deployment slots"
    $scHasDeploymentSlots = $false
    $deploymentSlotsSc = GetDeploymentSlots -appServiceNameParam $SCEPmanAppServiceName -resourceGroupParam $SCEPmanResourceGroup
    if($null -ne $deploymentSlotsSc -and $deploymentSlotsSc.Count -gt 0) {
        $scHasDeploymentSlots = $true
        Write-Information "$($deploymentSlotsSc.Count) found"
    } else {
        Write-Information "No deployment slots found"
    }
    if ($null -ne $DeploymentSlotName) {
        if (($deploymentSlotsSc | Where-Object { $_ -eq $DeploymentSlotName }).Count -gt 0) {
            Write-Information "Updating only deployment slot $DeploymentSlotName"
            $deploymentSlotsSc = @($DeploymentSlotName)
        } else {
            Write-Error "Only $DeploymentSlotName should be updated, but it was not found among the deployment slots: $([string]::join($deploymentSlotsSc))"
            throw "Only $DeploymentSlotName should be updated, but it was not found"
        }
    }

    Write-Information "Getting CertMaster web app"
    $CertMasterAppServiceName = CreateCertMasterAppService

    # Service principal of System-assigned identity of SCEPman
    $serviceprincipalsc = GetServicePrincipal -appServiceNameParam $SCEPmanAppServiceName -resourceGroupParam $SCEPmanResourceGroup

    # Service principal of System-assigned identity of CertMaster
    $serviceprincipalcm = GetServicePrincipal -appServiceNameParam $CertMasterAppServiceName -resourceGroupParam $SCEPmanResourceGroup

    $serviceprincipalOfScDeploymentSlots = @()

    if($true -eq $scHasDeploymentSlots) {
        ForEach($deploymentSlot in $deploymentSlotsSc) {
            $tempDeploymentSlot = GetServicePrincipal -appServiceNameParam $SCEPmanAppServiceName -resourceGroupParam $SCEPmanResourceGroup -slotNameParam $deploymentSlot
            if($null -eq $tempDeploymentSlot) {
                Write-Error "Deployment slot '$deploymentSlot' doesn't have managed identity turned on"
                throw "Deployment slot '$deploymentSlot' doesn't have managed identity turned on"
            }
            $serviceprincipalOfScDeploymentSlots += $tempDeploymentSlot
        }
    }

    SetTableStorageEndpointsInScAndCmAppSettings

    $CertMasterBaseURL = "https://$CertMasterAppServiceName.azurewebsites.net"
    Write-Verbose "CertMaster web app url is $CertMasterBaseURL"

    $graphResourceId = GetAzureResourceAppId -appId $MSGraphAppId
    $intuneResourceId = GetAzureResourceAppId -appId $IntuneAppId


    ### Set managed identity permissions for SCEPman
    $resourcePermissionsForSCEPman =
        @([pscustomobject]@{'resourceId'=$graphResourceId;'appRoleId'=$MSGraphDirectoryReadAllPermission;},
        [pscustomobject]@{'resourceId'=$graphResourceId;'appRoleId'=$MSGraphDeviceManagementReadPermission;},
        [pscustomobject]@{'resourceId'=$intuneResourceId;'appRoleId'=$IntuneSCEPChallengePermission;}
    )

    Write-Information "Setting up permissions for SCEPman"
    SetManagedIdentityPermissions -principalId $serviceprincipalsc.principalId -resourcePermissions $resourcePermissionsForSCEPman

    if($true -eq $scHasDeploymentSlots) {
        Write-Information "Setting up permissions for SCEPman deployment slots"
        ForEach($tempServicePrincipal in $serviceprincipalOfScDeploymentSlots) {
            SetManagedIdentityPermissions -principalId $tempServicePrincipal.principalId -resourcePermissions $resourcePermissionsForSCEPman
        }
    }

    Write-Information "Creating Azure AD app registration for SCEPman"
    ### SCEPman App Registration
    # Register SCEPman App
    $appregsc = RegisterAzureADApp -name $azureADAppNameForSCEPman -manifest $ScepmanManifest
    $spsc = CreateServicePrincipal -appId $($appregsc.appId)

    $ScepManSubmitCSRPermission = $appregsc.appRoles[0].id

    # Expose SCEPman API
    ExecuteAzCommandRobustly -azCommand "az ad app update --id $($appregsc.appId) --identifier-uris `"api://$($appregsc.appId)`""

    Write-Information "Allowing CertMaster to submit CSR requests to SCEPman API"
    # Allow CertMaster to submit CSR requests to SCEPman API
    $resourcePermissionsForCertMaster = @([pscustomobject]@{'resourceId'=$($spsc.objectId);'appRoleId'=$ScepManSubmitCSRPermission;})
    SetManagedIdentityPermissions -principalId $serviceprincipalcm.principalId -resourcePermissions $resourcePermissionsForCertMaster


    Write-Information "Creating Azure AD app registration for CertMaster"
    ### CertMaster App Registration

    # Register CertMaster App
    $appregcm = RegisterAzureADApp -name $azureADAppNameForCertMaster -manifest $CertmasterManifest -replyUrls `"$CertMasterBaseURL/signin-oidc`"
    $null = CreateServicePrincipal -appId $($appregcm.appId)

    Write-Verbose "Adding Delegated permission to CertMaster App Registration"
    # Add Microsoft Graph's User.Read as delegated permission for CertMaster
    AddDelegatedPermissionToCertMasterApp -appId $appregcm.appId


    Write-Information "Configuring SCEPman, SCEPman's deployment slots (if any), and CertMaster web app settings"
    
    $managedIdentityEnabledOn = ([DateTimeOffset]::UtcNow).ToUnixTimeSeconds()
    
    # Add ApplicationId and some additional defaults in SCEPman web app settings
    
    $ScepManAppSettings = "{\`"AppConfig:AuthConfig:ApplicationId\`":\`"$($appregsc.appId)\`",\`"AppConfig:CertMaster:URL\`":\`"$($CertMasterBaseURL)\`",\`"AppConfig:DirectCSRValidation:Enabled\`":\`"true\`",\`"AppConfig:AuthConfig:ManagedIdentityEnabledOnUnixTime\`":\`"$managedIdentityEnabledOn\`"}".Replace("`r", [String]::Empty).Replace("`n", [String]::Empty)

    if ($null -eq $DeploymentSlotName) {
        $existingApplicationId = az webapp config appsettings list --name $SCEPmanAppServiceName --resource-group $SCEPmanResourceGroup --query "[?name=='AppConfig:AuthConfig:ApplicationId'].value | [0]"
        if(![string]::IsNullOrEmpty($existingApplicationId) -and $existingApplicationId -ne $appregsc.appId) {
            $null = az webapp config appsettings set --name $SCEPmanAppServiceName --resource-group $SCEPmanResourceGroup --settings BackUp:AppConfig:AuthConfig:ApplicationId=$existingApplicationId
        }
        $null = az webapp config appsettings set --name $SCEPmanAppServiceName --resource-group $SCEPmanResourceGroup --settings $ScepManAppSettings
        $existingApplicationKeySc = az webapp config appsettings list --name $SCEPmanAppServiceName --resource-group $SCEPmanResourceGroup --query "[?name=='AppConfig:AuthConfig:ApplicationKey'].value | [0]"
        if(![string]::IsNullOrEmpty($existingApplicationKeySc)) {
            $null = az webapp config appsettings set --name $SCEPmanAppServiceName --resource-group $SCEPmanResourceGroup --settings BackUp:AppConfig:AuthConfig:ApplicationKey=$existingApplicationKeySc
            $null = az webapp config appsettings delete --name $SCEPmanAppServiceName --resource-group $SCEPmanResourceGroup --setting-names AppConfig:AuthConfig:ApplicationKey
        }
    }

    if($true -eq $scHasDeploymentSlots) {
        ForEach($tempDeploymentSlot in $deploymentSlotsSc) {
            $existingApplicationId = az webapp config appsettings list --name $SCEPmanAppServiceName --resource-group $SCEPmanResourceGroup --slot $tempDeploymentSlot --query "[?name=='AppConfig:AuthConfig:ApplicationId'].value | [0]"
            if(![string]::IsNullOrEmpty($existingApplicationId) -and $existingApplicationId -ne $appregsc.appId) {
                $null = az webapp config appsettings set --name $SCEPmanAppServiceName --resource-group $SCEPmanResourceGroup --settings BackUp:AppConfig:AuthConfig:ApplicationId=$existingApplicationId --slot $tempDeploymentSlot
            }
            $null = az webapp config appsettings set --name $SCEPmanAppServiceName --resource-group $SCEPmanResourceGroup --settings $ScepManAppSettings --slot $tempDeploymentSlot
            $existingApplicationKeySc = az webapp config appsettings list --name $SCEPmanAppServiceName --resource-group $SCEPmanResourceGroup --slot $tempDeploymentSlot --query "[?name=='AppConfig:AuthConfig:ApplicationKey'].value | [0]"
            if(![string]::IsNullOrEmpty($existingApplicationKeySc)) {
                $null = az webapp config appsettings set --name $SCEPmanAppServiceName --resource-group $SCEPmanResourceGroup --slot $tempDeploymentSlot --settings BackUp:AppConfig:AuthConfig:ApplicationKey=$existingApplicationKeySc
                $null = az webapp config appsettings delete --name $SCEPmanAppServiceName --resource-group $SCEPmanResourceGroup --slot $tempDeploymentSlot --setting-names AppConfig:AuthConfig:ApplicationKey
            }
        }
    }

    # Add ApplicationId and SCEPman API scope in certmaster web app settings
    $CertmasterAppSettings = "{\`"AppConfig:AuthConfig:ApplicationId\`":\`"$($appregcm.appId)\`",\`"AppConfig:AuthConfig:SCEPmanAPIScope\`":\`"api://$($appregsc.appId)\`",\`"AppConfig:AuthConfig:ManagedIdentityEnabledOnUnixTime\`":\`"$managedIdentityEnabledOn\`"}".Replace("`r", [String]::Empty).Replace("`n", [String]::Empty)
    $null = az webapp config appsettings set --name $CertMasterAppServiceName --resource-group $SCEPmanResourceGroup --settings $CertmasterAppSettings

    Write-Information "SCEPman and CertMaster configuration completed"
}

Export-ModuleMember -Function Complete-SCEPmanInstallation