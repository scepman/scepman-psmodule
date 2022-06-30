<#
 .Synopsis
  Adds the required configuration to SCEPman (https://scepman.com/) right after installing or updating to a 2.x version.

 .Parameter SCEPmanAppServiceName
  The name of the existing SCEPman App Service. Leave empty to get prompted.

 .Parameter CertMasterAppServiceName
  The name of the SCEPman Certificate Master App Service to be created. Leave empty if it exists already. If it does not exist and the parameter is $null, you will be prompted.

 .Parameter SCEPmanResourceGroup
  The Azure resource group hosting the SCEPman App Service. Leave empty for auto-detection.

 .Parameter CertMasterResourceGroup
  The Azure resource group hosting the SCEPman Certificate Master App Service. Leave empty to use the same as the SCEPman main app service.

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
    param(
        $SCEPmanAppServiceName,
        $CertMasterAppServiceName,
        $SCEPmanResourceGroup,
        $CertMasterResourceGroup,
        [switch]$SearchAllSubscriptions,
        $DeploymentSlotName,
        $SubscriptionId,
        $AzureADAppNameForSCEPman = 'SCEPman-api',
        $AzureADAppNameForCertMaster = 'SCEPman-CertMaster')

    $version = $MyInvocation.MyCommand.ScriptBlock.Module.Version
    Write-Verbose "Invoked $($MyInvocation.MyCommand) from SCEPman Module version $version"

    if ([String]::IsNullOrWhiteSpace($SCEPmanAppServiceName)) {
        $SCEPmanAppServiceName = Read-Host "Please enter the SCEPman app service name"
    }

    Write-Information "Installing az resource graph extension"
    az extension add --name resource-graph --only-show-errors

    Write-Information "Configuring SCEPman and CertMaster"

    Write-Information "Logging in to az"
    $null = AzLogin

    Write-Information "Getting subscription details"
    $subscription = GetSubscriptionDetails -AppServiceName $SCEPmanAppServiceName -SearchAllSubscriptions $SearchAllSubscriptions.IsPresent -SubscriptionId $SubscriptionId
    Write-Information "Subscription is set to $($subscription.name)"

    Write-Information "Setting resource group"
    if ([String]::IsNullOrWhiteSpace($SCEPmanResourceGroup)) {
        # No resource group given, search for it now
        $SCEPmanResourceGroup = GetResourceGroup -SCEPmanAppServiceName $SCEPmanAppServiceName
    }

    if ([String]::IsNullOrWhiteSpace($CertMasterResourceGroup)) {
        $CertMasterResourceGroup = $SCEPmanResourceGroup
    }

    Write-Information "Getting SCEPman deployment slots"
    $deploymentSlotsSc = GetDeploymentSlots -appServiceName $SCEPmanAppServiceName -resourceGroup $SCEPmanResourceGroup
    Write-Information "$($deploymentSlotsSc.Count) deployment slots found"

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
    $CertMasterAppServiceName = CreateCertMasterAppService -TenantId $subscription.tenantId -SCEPmanAppServiceName $SCEPmanAppServiceName -SCEPmanResourceGroup $SCEPmanResourceGroup -CertMasterAppServiceName $CertMasterAppServiceName -CertMasterResourceGroup $CertMasterResourceGroup -DeploymentSlotName $DeploymentSlotName

    # Service principal of System-assigned identity of SCEPman
    $serviceprincipalsc = GetServicePrincipal -appServiceNameParam $SCEPmanAppServiceName -resourceGroupParam $SCEPmanResourceGroup

    # Service principal of System-assigned identity of CertMaster
    $serviceprincipalcm = GetServicePrincipal -appServiceNameParam $CertMasterAppServiceName -resourceGroupParam $CertMasterResourceGroup

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

    SwitchToConfiguredChannel -AppServiceName $SCEPmanAppServiceName -ResourceGroup $SCEPmanResourceGroup -ChannelArtifacts $Artifacts_Scepman
    SwitchToConfiguredChannel -AppServiceName $CertMasterAppServiceName -ResourceGroup $CertMasterResourceGroup -ChannelArtifacts $Artifacts_Certmaster

    SetTableStorageEndpointsInScAndCmAppSettings -SubscriptionId $subscription.Id -SCEPmanAppServiceName $SCEPmanAppServiceName -SCEPmanResourceGroup $SCEPmanResourceGroup -CertMasterAppServiceName $CertMasterAppServiceName -CertMasterResourceGroup $CertMasterResourceGroup -DeploymentSlotName $DeploymentSlotName -servicePrincipals $servicePrincipals -DeploymentSlots $deploymentSlotsSc

    ### Set managed identity permissions for SCEPman
    $resourcePermissionsForSCEPman = GetSCEPmanResourcePermissions

    Write-Information "Setting up permissions for SCEPman"
    SetManagedIdentityPermissions -principalId $serviceprincipalsc.principalId -resourcePermissions $resourcePermissionsForSCEPman

    if($true -eq $scHasDeploymentSlots) {
        Write-Information "Setting up permissions for SCEPman deployment slots"
        ForEach($tempServicePrincipal in $serviceprincipalOfScDeploymentSlots) {
            SetManagedIdentityPermissions -principalId $tempServicePrincipal.principalId -resourcePermissions $resourcePermissionsForSCEPman
        }
    }

    $appregsc = CreateSCEPmanAppRegistration -AzureADAppNameForSCEPman $AzureADAppNameForSCEPman -CertMasterServicePrincipalId $serviceprincipalcm.principalId

    $CertMasterHostName = GetAppServiceHostName -appServiceName $CertMasterAppServiceName -SCEPmanResourceGroup $SCEPmanResourceGroup
    $CertMasterBaseURL = "https://$CertMasterHostName"
    Write-Verbose "CertMaster web app url is $CertMasterBaseURL"

    $appregcm = CreateCertMasterAppRegistration -AzureADAppNameForCertMaster $AzureADAppNameForCertMaster -CertMasterBaseURL $CertMasterBaseURL

    ConfigureAppServices -SCEPmanAppServiceName $SCEPmanAppServiceName -SCEPmanResourceGroup $SCEPmanResourceGroup -CertMasterAppServiceName $CertMasterAppServiceName -CertMasterResourceGroup $CertMasterResourceGroup -DeploymentSlotName $DeploymentSlotName -CertMasterBaseURL $CertMasterBaseURL -SCEPmanAppId $appregsc.appId -CertMasterAppId $appregcm.appId -DeploymentSlots $deploymentSlotsSc

    Write-Information "SCEPman and SCEPman Certificate Master configuration completed"
}