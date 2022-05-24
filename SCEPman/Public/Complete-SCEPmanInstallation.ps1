<#
 .Synopsis
  Adds the required configuration to SCEPman (https://scepman.com/) right after installing or updating to a 2.x version.

 .Parameter SCEPmanAppServiceName
  The name of the existing SCEPman App Service. Leave empty to get prompted.

 .Parameter CertMasterAppServiceName
  The name of the SCEPman Certificate Master App Service to be created. Leave empty if it exists already. If it does not exist and the parameter is $null, you will be prompted.

 .Parameter SCEPmanResourceGroup
  The Azure resource group hosting the SCEPman App Service. Leave empty for auto-detection.

 .Parameter SearchAllSubscriptions
  Set this flag to search all subscriptions for the SCEPman App Service. Otherwise, pre-select the right subscription in az or pass in the correct SubscriptionId.

 .Parameter DeploymentSlotName
  If you want to configure a specific SCEPman Deployment Slot, pass in its name. Otherwise, all Deployment Slots are configured

 .Parameter SubscriptionId
  The ID of the Subscription where SCEPman is installed. Can be omitted if it is pre-selected in az already or use the SearchAllSubscriptions flag to search all accessible subscriptions

 .Parameter AzureADAppNameForSCEPman
  Name of the Azure AD app registration for SCEPman

 .Parameter AzureADAppNameForCertMaster
  Name of the Azure AD app registration for SCEPman Certificate Master

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
    param($SCEPmanAppServiceName, $CertMasterAppServiceName, $SCEPmanResourceGroup, [switch]$SearchAllSubscriptions, $DeploymentSlotName, $SubscriptionId, $AzureADAppNameForSCEPman = 'SCEPman-api', $AzureADAppNameForCertMaster = 'SCEPman-CertMaster')

    if ([String]::IsNullOrWhiteSpace($SCEPmanAppServiceName)) {
        $SCEPmanAppServiceName = Read-Host "Please enter the SCEPman app service name"
    }

    Write-Information "Installing az resource graph extension"
    az extension add --name resource-graph --only-show-errors

    Write-Information "Configuring SCEPman and CertMaster"

    Write-Information "Logging in to az"
    AzLogin

    Write-Information "Getting subscription details"
    $subscription = GetSubscriptionDetails -SCEPmanAppServiceName $SCEPmanAppServiceName -SearchAllSubscriptions $SearchAllSubscriptions.IsPresent -SubscriptionId $SubscriptionId
    Write-Information "Subscription is set to $($subscription.name)"

    Write-Information "Setting resource group"
    if ([String]::IsNullOrWhiteSpace($SCEPmanResourceGroup)) {
        # No resource group given, search for it now    
        $SCEPmanResourceGroup = GetResourceGroup -SCEPmanAppServiceName $SCEPmanAppServiceName
    }

    Write-Information "Getting SCEPman deployment slots"
    $scHasDeploymentSlots = $false
    $deploymentSlotsSc = GetDeploymentSlots -appServiceName $SCEPmanAppServiceName -resourceGroup $SCEPmanResourceGroup
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
    $CertMasterAppServiceName = CreateCertMasterAppService -TenantId $subscription.tenantId -SCEPmanAppServiceName $SCEPmanAppServiceName -SCEPmanResourceGroup $SCEPmanResourceGroup -CertMasterAppServiceName $CertMasterAppServiceName -DeploymentSlotName $DeploymentSlotName

    # Service principal of System-assigned identity of SCEPman
    $serviceprincipalsc = GetServicePrincipal -appServiceNameParam $SCEPmanAppServiceName -resourceGroupParam $SCEPmanResourceGroup

    # Service principal of System-assigned identity of CertMaster
    $serviceprincipalcm = GetServicePrincipal -appServiceNameParam $CertMasterAppServiceName -resourceGroupParam $SCEPmanResourceGroup

    $servicePrincipals = [System.Collections.ArrayList]@( $serviceprincipalsc.principalId, $serviceprincipalcm.principalId )

    if($true -eq $scHasDeploymentSlots) {
        ForEach($deploymentSlot in $deploymentSlotsSc) {
            $tempDeploymentSlot = GetServicePrincipal -appServiceNameParam $SCEPmanAppServiceName -resourceGroupParam $SCEPmanResourceGroup -slotNameParam $deploymentSlot
            if($null -eq $tempDeploymentSlot) {
                Write-Error "Deployment slot '$deploymentSlot' doesn't have managed identity turned on"
                throw "Deployment slot '$deploymentSlot' doesn't have managed identity turned on"
            }
            $serviceprincipalOfScDeploymentSlots += $tempDeploymentSlot
            $servicePrincipals.Add($tempDeploymentSlot.principalId)
        }
    }

    SetTableStorageEndpointsInScAndCmAppSettings -SubscriptionId $subscription.Id -SCEPmanAppServiceName $SCEPmanAppServiceName -SCEPmanResourceGroup $SCEPmanResourceGroup -CertMasterAppServiceName $CertMasterAppServiceName -DeploymentSlotName $DeploymentSlotName -servicePrincipals $servicePrincipals

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

    CreateSCEPmanAppRegistration -AzureADAppNameForSCEPman $AzureADAppNameForSCEPman -CertMasterServicePrincipalId $serviceprincipalcm.principalId

    $CertMasterBaseURL = "https://$CertMasterAppServiceName.azurewebsites.net"  #TODO: Find out CertMaster Base URL for non-global tenants
    Write-Verbose "CertMaster web app url is $CertMasterBaseURL"

    CreateCertMasterAppRegistration -AzureADAppNameForCertMaster $AzureADAppNameForCertMaster -CertMasterBaseURL $CertMasterBaseURL

    ConfigureAppServices -SCEPmanAppServiceName $SCEPmanAppServiceName -SCEPmanResourceGroup $SCEPmanResourceGroup -CertMasterAppServiceName $CertMasterAppServiceName -DeploymentSlotName $DeploymentSlotName -CertMasterBaseURL $CertMasterBaseURL -SCEPmanAppId $appregsc.appId -CertMasterAppId $appregcm.appId

    Write-Information "SCEPman and CertMaster configuration completed"
}