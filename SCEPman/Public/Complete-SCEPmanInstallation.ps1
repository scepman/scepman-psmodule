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
    param($SCEPmanAppServiceName, $CertMasterAppServiceName, $SCEPmanResourceGroup, [switch]$SearchAllSubscriptions, $DeploymentSlotName, $SubscriptionId)

    if ([String]::IsNullOrWhiteSpace($SCEPmanAppServiceName)) {
        $SCEPmanAppServiceName = Read-Host "Please enter the SCEPman app service name"
    }

    Write-Information "Installing az resource graph extension"
    az extension add --name resource-graph --only-show-errors

    Write-Information "Configuring SCEPman and CertMaster"

    Write-Information "Logging in to az"
    AzLogin

    Write-Information "Getting subscription details"
    $subscription = GetSubscriptionDetails -SearchAllSubscriptions $SearchAllSubscriptions -SubscriptionId $SubscriptionId
    Write-Information "Subscription is set to $($subscription.name)"

    Write-Information "Setting resource group"
    if ([String]::IsNullOrWhiteSpace($SCEPmanResourceGroup)) {
        # No resource group given, search for it now    
        $SCEPmanResourceGroup = GetResourceGroup -SCEPmanAppServiceName $SCEPmanAppServiceName
    }

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

    $ScepManAppSettings = "{\`"AppConfig:AuthConfig:ApplicationId\`":\`"$($appregsc.appId)\`",\`"AppConfig:CertMaster:URL\`":\`"$($CertMasterBaseURL)\`",\`"AppConfig:IntuneValidation:DeviceDirectory\`":\`"AADAndIntune\`",\`"AppConfig:DirectCSRValidation:Enabled\`":\`"true\`",\`"AppConfig:AuthConfig:ManagedIdentityEnabledOnUnixTime\`":\`"$managedIdentityEnabledOn\`"}".Replace("`r", [String]::Empty).Replace("`n", [String]::Empty)

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