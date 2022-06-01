<#
 .Synopsis
  Adds an App Service Deployment Slot to an existing SCEPman configuration

 .Parameter SCEPmanAppServiceName
  The name of the existing SCEPman App Service. Leave empty to get prompted.

 .Parameter SCEPmanResourceGroup
  The Azure resource group hosting the SCEPman App Service. Leave empty for auto-detection.

 .Parameter SearchAllSubscriptions
  Set this flag to search all subscriptions for the SCEPman App Service. Otherwise, pre-select the right subscription in az or pass in the correct SubscriptionId.

 .Parameter DeploymentSlotName
  The name of the Deployment slot to be created

 .Parameter SubscriptionId
  The ID of the Subscription where SCEPman is installed. Can be omitted if it is pre-selected in az already or use the SearchAllSubscriptions flag to search all accessible subscriptions

 .Example
   # Add a new pre-release deployment slot to the existing SCEPman App Service as-scepman
   Add-SCEPmanDeploymentSlot -SCEPmanAppServiceName as-scepman -DeploymentSlotName pre-release

#>
function Add-SCEPmanDeploymentSlot
{
    [CmdletBinding()]
    param(
      $SCEPmanAppServiceName, 
      $SCEPmanResourceGroup, 
      [switch]$SearchAllSubscriptions, 
      [Parameter(Mandatory=$true)]$DeploymentSlotName, 
      $SubscriptionId)

    $version = $MyInvocation.MyCommand.ScriptBlock.Module.Version
    Write-Verbose "Invoked $($MyInvocation.MyCommand) from SCEPman Module version $version"

    if ([String]::IsNullOrWhiteSpace($SCEPmanAppServiceName)) {
        $SCEPmanAppServiceName = Read-Host "Please enter the SCEPman app service name"
    }

    Write-Information "Installing az resource graph extension"
    az extension add --name resource-graph --only-show-errors

    Write-Information "Adding SCEPman Deployment Slot $DeploymentSlotName"

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

    Write-Information "Getting existing SCEPman deployment slots"
    $deploymentSlotsSc = GetDeploymentSlots -appServiceName $SCEPmanAppServiceName -resourceGroup $SCEPmanResourceGroup
    if($null -ne $deploymentSlotsSc -and $deploymentSlotsSc.Count -gt 0) {
        Write-Information "$($deploymentSlotsSc.Count) found"
    } else {
        Write-Information "No deployment slots found"
    }

    if (($deploymentSlotsSc | Where-Object { $_ -eq $DeploymentSlotName }).Count -gt 0) {
        Write-Error "Deployment slot $DeploymentSlotName already exists. Aborting ..."
        throw "Deployment slot $DeploymentSlotName already exists."
    }

    # Returns the Service principal of the deployment slot
    Write-Information "Creating new Deployment Slot $DeploymentSlotName"
    $serviceprincipalsc = CreateSCEPmanDeploymentSlot -SCEPmanAppServiceName $SCEPmanAppServiceName -SCEPmanResourceGroup $SCEPmanResourceGroup -DeploymentSlotName $DeploymentSlotName
    $servicePrincipals = @( $serviceprincipalsc.principalId )
    Write-Debug "Created SCEPman Deployment Slot has Managed Identity Principal $serviceprincipalsc"
   
    Write-Information "Adding permissions to Storage Account"
    $existingTableStorageEndpointSetting = GetSCEPmanStorageAccountConfig -SCEPmanResourceGroup $SCEPmanResourceGroup -SCEPmanAppServiceName $SCEPmanAppServiceName -DeploymentSlotName $DeploymentSlotName
    $storageAccountTableEndpoint = $existingTableStorageEndpointSetting.Trim('"')
    if(-not [string]::IsNullOrEmpty($storageAccountTableEndpoint)) {
      Write-Verbose "Storage Account Table Endpoint $storageAccountTableEndpoint found"
      $ScStorageAccount = GetExistingStorageAccount -dataTableEndpoint $storageAccountTableEndpoint
      SetStorageAccountPermissions -SubscriptionId $subscription.Id -ScStorageAccount $ScStorageAccount -servicePrincipals $servicePrincipals
    } else {
        Write-Warning "No Storage Account found. Not adding any permissions."
    }

    Write-Information "Adding permissions Graph and Intune"
    $graphResourceId = GetAzureResourceAppId -appId $MSGraphAppId
    $intuneResourceId = GetAzureResourceAppId -appId $IntuneAppId

    ### Set managed identity permissions for SCEPman
    $resourcePermissionsForSCEPman =
        @([pscustomobject]@{'resourceId'=$graphResourceId;'appRoleId'=$MSGraphDirectoryReadAllPermission;},
        [pscustomobject]@{'resourceId'=$graphResourceId;'appRoleId'=$MSGraphDeviceManagementReadPermission;},
        [pscustomobject]@{'resourceId'=$intuneResourceId;'appRoleId'=$IntuneSCEPChallengePermission;}
    )

    SetManagedIdentityPermissions -principalId $serviceprincipalsc.principalId -resourcePermissions $resourcePermissionsForSCEPman

    Write-Information "Adding permissions to Key Vault"
    $keyvaultname = FindConfiguredKeyVault -SCEPmanAppServiceName $SCEPmanAppServiceName -SCEPmanResourceGroup $SCEPmanResourceGroup
    Write-Verbose "Key vault $keyvaultname identified"
    AddSCEPmanPermissionsToKeyVault -KeyVaultName $keyvaultname -PrincipalId $serviceprincipalsc.principalId

    # Add a setting to tell the Deployment slot that it has been configured

    Write-Information "SCEPman Deployment Slot $DeploymentSlotName successfully created"
}