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

 .PARAMETER SkipAppRoleAssignments
  Set this flag to skip the app role assignments. This is useful if you don't have Global Administrator permissions. You will have to assign the app roles manually later, but the CMDlet will show which az commands to execute manually for the assignment.

 .PARAMETER SkipCertificateMaster
  Set this flag to skip configuration of the Certificate Master App Service. This is useful for SCEPman clones, where the Certificate Master App Service already exists next to the main instance.

 .Parameter AzureADAppNameForSCEPman
  Name of the Azure AD app registration for SCEPman

 .Parameter AzureADAppNameForCertMaster
  Name of the Azure AD app registration for SCEPman Certificate Master

 .PARAMETER GraphBaseUri
  URI of Microsoft Graph. This is https://graph.microsoft.com/ for the global cloud (default) and https://graph.microsoft.us/ for the GCC High cloud.

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
        [switch]$SkipAppRoleAssignments,
        [switch]$SkipCertificateMaster,
        $AzureADAppNameForSCEPman = 'SCEPman-api',
        $AzureADAppNameForCertMaster = 'SCEPman-CertMaster',
        $GraphBaseUri = 'https://graph.microsoft.com'
        )

    $version = $MyInvocation.MyCommand.ScriptBlock.Module.Version
    Write-Verbose "Invoked $($MyInvocation.MyCommand)"
    Write-Information "SCEPman Module version $version on PowerShell $($PSVersionTable.PSVersion)"

    if ($SkipCertificateMaster.IsPresent -and ($null -ne $CertMasterAppServiceName -or $null -ne $CertMasterResourceGroup)) {
        Write-Error "You cannot specify a Certificate Master App Service name or resource group and skip the configuration of the Certificate Master App Service at the same time. Error: -SkipCertificateMaster is set and -CertMasterAppServiceName or -CertMasterResourceGroup is set"
        throw "You cannot specify a Certificate Master App Service name and skip the configuration of the Certificate Master App Service at the same time."
    }

    $cliVersion = [Version]::Parse((GetAzVersion).'azure-cli')
    Write-Information "Detected az version: $cliVersion"

    If ($PSBoundParameters['Debug']) {
        $DebugPreference='Continue' # Do not ask user for confirmation, so that the script can run unattended
    }

    if ([String]::IsNullOrWhiteSpace($SCEPmanAppServiceName)) {
        $SCEPmanAppServiceName = Read-Host "Please enter the SCEPman app service name"
    }

    $GraphBaseUri = $GraphBaseUri.TrimEnd('/')

    Write-Information "Installing az resource graph extension"
    az extension add --name resource-graph --only-show-errors

    Write-Information "Configuring SCEPman"

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

    if (-not $SkipCertificateMaster.IsPresent) {
        Write-Information "Getting Certificate Master web app"
        $CertMasterAppServiceName = CreateCertMasterAppService -TenantId $subscription.tenantId -SCEPmanAppServiceName $SCEPmanAppServiceName -SCEPmanResourceGroup $SCEPmanResourceGroup -CertMasterAppServiceName $CertMasterAppServiceName -CertMasterResourceGroup $CertMasterResourceGroup -DeploymentSlotName $DeploymentSlotName
    }

    Write-Verbose "Collecting Service Principals of SCEPman, its deployment slots, and Certificate Master"
    $serviceprincipalOfScDeploymentSlots = [System.Collections.ArrayList]@( )
    $servicePrincipals = [System.Collections.ArrayList]@( )

    # Service principal of System-assigned identity of SCEPman
    $serviceprincipalsc = GetServicePrincipal -appServiceNameParam $SCEPmanAppServiceName -resourceGroupParam $SCEPmanResourceGroup

    $smUserAssignedMSIPrincipals = GetUserAssignedPrincipalIdsFromServicePrincipal -servicePrincipal $serviceprincipalsc
    if ($smUserAssignedMSIPrincipals.Count -gt 0) {
        Write-Information "SCEPman has $($smUserAssignedMSIPrincipals.Count) user-assigned managed identities, which will be configured."
        $servicePrincipals.AddRange($smUserAssignedMSIPrincipals)
        $serviceprincipalOfScDeploymentSlots.AddRange($smUserAssignedMSIPrincipals)
    }
    if ($null -eq $serviceprincipalsc.principalId) {
        Write-Information "SCEPman does not have a System-assigned Managed Identity turned on"
        if ($smUserAssignedMSIPrincipals.Count -eq 0) {
            Write-Error "SCEPman does not have a System-assigned Managed Identity turned on and no user-assigned managed identities were found. Please turn on the System-assigned Managed Identity."
            throw "SCEPman does not have a System-assigned Managed Identity turned on and no user-assigned managed identities were found. Please turn on the System-assigned Managed Identity."
        }
    } else {
        $null = $serviceprincipalOfScDeploymentSlots.Add($serviceprincipalsc.principalId)
        $null = $servicePrincipals.Add($serviceprincipalsc.principalId)
    }

    # Service principal of System-assigned identity of CertMaster
    if (-not $SkipCertificateMaster.IsPresent) {
        $serviceprincipalcm = GetServicePrincipal -appServiceNameParam $CertMasterAppServiceName -resourceGroupParam $CertMasterResourceGroup

        if ($null -eq $serviceprincipalcm.principalId) {
            Write-Error "Certificate Master does not have a System-assigned Managed Identity turned on. Please turn on the System-assigned Managed Identity."
        } else {
            $null = $servicePrincipals.Add($serviceprincipalcm.principalId)
        }

        $cmUserAssignedMSIPrincipals = GetUserAssignedPrincipalIdsFromServicePrincipal -servicePrincipal $serviceprincipalcm
        if ($cmUserAssignedMSIPrincipals.Count -gt 0) {
            Write-Warning "Certificate Master has user-assigned managed identities. This is not supported by this CMDlet. Please configure the app roles manually."
            $servicePrincipals.AddRange($cmUserAssignedMSIPrincipals)   # Let's still try it. It reduces the manual work.
        }
    }

    if($deploymentSlotsSc.Count -gt 0) {
        ForEach($deploymentSlot in $deploymentSlotsSc) {
            $tempDeploymentSlot = GetServicePrincipal -appServiceNameParam $SCEPmanAppServiceName -resourceGroupParam $SCEPmanResourceGroup -slotNameParam $deploymentSlot
            if($null -eq $tempDeploymentSlot) {
                Write-Error "Deployment slot '$deploymentSlot' doesn't have managed identity turned on"
                throw "Deployment slot '$deploymentSlot' doesn't have managed identity turned on"
            }
            $null = $serviceprincipalOfScDeploymentSlots.Add($tempDeploymentSlot.principalId)
            $null = $servicePrincipals.Add($tempDeploymentSlot.principalId)
        }
    }

    Write-Verbose "Checking update channel of SCEPman"
    SwitchToConfiguredChannel -AppServiceName $SCEPmanAppServiceName -ResourceGroup $SCEPmanResourceGroup -ChannelArtifacts $Artifacts_Scepman
    if (-not $SkipCertificateMaster.IsPresent) {
        Write-Verbose "Checking update channel of Certificate Master"
        SwitchToConfiguredChannel -AppServiceName $CertMasterAppServiceName -ResourceGroup $CertMasterResourceGroup -ChannelArtifacts $Artifacts_Certmaster
    }

    Write-Information "Connecting Web Apps to Storage Account"
    SetTableStorageEndpointsInScAndCmAppSettings -SubscriptionId $subscription.Id -SCEPmanAppServiceName $SCEPmanAppServiceName -SCEPmanResourceGroup $SCEPmanResourceGroup -CertMasterAppServiceName $CertMasterAppServiceName -CertMasterResourceGroup $CertMasterResourceGroup -DeploymentSlotName $DeploymentSlotName -servicePrincipals $servicePrincipals -DeploymentSlots $deploymentSlotsSc

    Write-Information "Adding permissions for SCEPman on the Key Vault"
    $keyVault = FindConfiguredKeyVault -SCEPmanResourceGroup $SCEPmanResourceGroup -SCEPmanAppServiceName $SCEPmanAppServiceName
    foreach ($scepmanServicePrincipal in $serviceprincipalOfScDeploymentSlots) {
        AddSCEPmanPermissionsToKeyVault -KeyVault $keyVault -PrincipalId $scepmanServicePrincipal
    }

    ### Set managed identity permissions for SCEPman
    $permissionLevelScepman = [int]::MaxValue    # the same level for all deployment slots and user-assigned managed identities, this makes it easier to manage the level. This will be overwritten at least once.
    Write-Information "Setting up permissions for SCEPman and its deployment slots"
    $resourcePermissionsForSCEPman = GetSCEPmanResourcePermissions
    ForEach($tempServicePrincipal in $serviceprincipalOfScDeploymentSlots) {
        Write-Verbose "Setting SCEPman permissions to Service Principal with id $tempServicePrincipal"
        $permissionLevelReached = SetManagedIdentityPermissions -principalId $tempServicePrincipal -resourcePermissions $resourcePermissionsForSCEPman -GraphBaseUri $GraphBaseUri -SkipAppRoleAssignments $SkipAppRoleAssignments
        if ($permissionLevelReached -lt $permissionLevelScepman) {
            $permissionLevelScepman = $permissionLevelReached
        }
        Write-Verbose "Reaching permission level $permissionLevelReached for this deployment slot"
    }
    Write-Information "SCEPman's permission level is $permissionLevelScepman"

    $permissionLevelCertMaster = -1

    ### Set Managed Identity permissions for CertMaster
    if (-not $SkipCertificateMaster.IsPresent) {
        Write-Information "Setting up permissions for Certificate Master"
        $resourcePermissionsForCertMaster = GetCertMasterResourcePermissions
        $permissionLevelCertMaster = SetManagedIdentityPermissions -principalId $serviceprincipalcm.principalId -resourcePermissions $resourcePermissionsForCertMaster -GraphBaseUri $GraphBaseUri -SkipAppRoleAssignments $SkipAppRoleAssignments
        Write-Information "Certificate Master's permission level is $permissionLevelCertMaster"

        $appregsc = CreateSCEPmanAppRegistration -AzureADAppNameForSCEPman $AzureADAppNameForSCEPman -CertMasterServicePrincipalId $serviceprincipalcm.principalId -GraphBaseUri $GraphBaseUri

        $CertMasterHostNames = GetAppServiceHostNames -appServiceName $CertMasterAppServiceName -SCEPmanResourceGroup $SCEPmanResourceGroup
        $CertMasterBaseURLs = @($CertMasterHostNames | ForEach-Object { "https://$_" })
        $CertMasterBaseURL = $CertMasterBaseURLs[0]
        Write-Verbose "CertMaster web app url are $CertMasterBaseURL"

        $appregcm = CreateCertMasterAppRegistration -AzureADAppNameForCertMaster $AzureADAppNameForCertMaster -CertMasterBaseURLs $CertMasterBaseURLs -SkipAutoGrant $SkipAppRoleAssignments
    }

    Write-Information "Configuring settings for the SCEPman web app and its deployment slots (if any)"
    ConfigureScepManAppService -SCEPmanAppServiceName $SCEPmanAppServiceName -SCEPmanResourceGroup $SCEPmanResourceGroup -DeploymentSlotName $null -CertMasterBaseURL $CertMasterBaseURL -SCEPmanAppId $appregsc.appId -PermissionLevel $permissionLevelScepman
    foreach ($currentDeploymentSlot in $deploymentSlotsSc) {
        ConfigureScepManAppService -SCEPmanAppServiceName $SCEPmanAppServiceName -SCEPmanResourceGroup $SCEPmanResourceGroup -DeploymentSlotName $currentDeploymentSlot -CertMasterBaseURL $CertMasterBaseURL -SCEPmanAppId $appregsc.appId -PermissionLevel $permissionLevelScepman
    }
    
    if ($SkipCertificateMaster.IsPresent) {
        Write-Information "Skipping configuration of Certificate Master App Service"
    } else {
        ConfigureCertMasterAppService -CertMasterAppServiceName $CertMasterAppServiceName -CertMasterResourceGroup $CertMasterResourceGroup -SCEPmanAppId $appregsc.appId -CertMasterAppId $appregcm.appId -PermissionLevel $permissionLevelCertMaster
    }

    Write-Information "SCEPman configuration completed"
}