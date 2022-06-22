<#
 .Synopsis
  Clones a SCEPman App Service adding the required permissions

 .Parameter SourceAppServiceName
  The name of the existing SCEPman App Service.

 .Parameter SourceResourceGroup
  The Azure resource group hosting the existing SCEPman App Service. Leave empty for auto-detection.

 .Parameter SourceSubscriptionId
  The ID of the Subscription where SCEPman is installed. Can be omitted if it is pre-selected in az already or use the SearchAllSubscriptions flag to search all accessible subscriptions

 .Parameter SearchAllSubscriptions
  Set this flag to search all subscriptions for the SCEPman App Service. Otherwise, pre-select the right subscription in az or pass in the correct SubscriptionId.

 .Parameter TargetAppServiceName
  The name of the new cloned SCEPman App Service.

 .PARAMETER TargetAppServicePlan
  The name of the App Service Plan for the cloned SCEPman instance. The App Service Plan must exist already in the TargetResourceGroup

 .Parameter TargetResourceGroup
  The Azure resource group hosting the new SCEPman App Service.

 .Parameter TargetSubscriptionId
  The ID of the Subscription where SCEPman shall be installed. Can be omitted if it is the same aqs SourceSubscriptionId or use the SearchAllSubscriptions flag to search all accessible subscriptions

 .Example
   # Create a SCEPman instance as-scepman-clone, which is a clone of the original app service as-scepman. It uses the App Service Plan asp-scepman-geo2
   New-SCEPmanClone -SourceAppServiceName as-scepman -TargetAppServiceName as-scepman-clone -TargetAppServicePlan asp-scepman-geo2 -SearchAllSubscriptions 6>&1

#>
function New-SCEPmanClone
{
    [CmdletBinding()]
    param(
      [Parameter(Mandatory=$true)]$SourceAppServiceName,
      $SourceResourceGroup,
      $SourceSubscriptionId,
      [Parameter(Mandatory=$true)]$TargetAppServiceName,
      [Parameter(Mandatory=$true)]$TargetAppServicePlan,
      $TargetResourceGroup,
      $TargetSubscriptionId,
      [switch]$SearchAllSubscriptions
      )

    $version = $MyInvocation.MyCommand.ScriptBlock.Module.Version
    Write-Verbose "Invoked $($MyInvocation.MyCommand) from SCEPman Module version $version"

    Write-Information "Installing az resource graph extension"
    az extension add --name resource-graph --only-show-errors

    Write-Information "Logging in to az"
    AzLogin

    Write-Information "Getting subscription details"
    $sourceSubscription = GetSubscriptionDetails -AppServiceName $SourceAppServiceName -SearchAllSubscriptions $SearchAllSubscriptions.IsPresent -SubscriptionId $SourceSubscriptionId
    Write-Information "Source Subscription is set to $($sourceSubscription.name)"

    Write-Information "Setting source resource group"
    if ([String]::IsNullOrWhiteSpace($SourceResourceGroup)) {
        # No resource group given, search for it now
        $SourceResourceGroup = GetResourceGroup -SCEPmanAppServiceName $SourceAppServiceName
    }

    Write-Information "Reading base App Service settings from source"
    $SCEPmanSourceSettings = ReadAppSettings -AppServiceName $SourceAppServiceName -resourceGroup $SourceResourceGroup

    Write-Information "Reading storage account informaton from source"
    $existingTableStorageEndpointSetting = GetSCEPmanStorageAccountConfig -SCEPmanResourceGroup $SourceResourceGroup -SCEPmanAppServiceName $SourceAppServiceName
    $storageAccountTableEndpoint = $existingTableStorageEndpointSetting.Trim('"')
    if(-not [string]::IsNullOrEmpty($storageAccountTableEndpoint)) {
        Write-Verbose "Storage Account Table Endpoint $storageAccountTableEndpoint found"
        $ScStorageAccount = GetExistingStorageAccount -dataTableEndpoint $storageAccountTableEndpoint
    } else {
        Write-Warning "No Storage Account found. Not adding any permissions."
    }

    Write-Information "Reading Key Vault registration from source"
    $keyvaultname = FindConfiguredKeyVault -SCEPmanAppServiceName $SourceAppServiceName -SCEPmanResourceGroup $SourceResourceGroup
    Write-Verbose "Key Vault $keyvaultname identified"

    Write-Information "Getting target subscription details"
    $targetSubscription = GetSubscriptionDetails -AppServicePlanName $TargetAppServicePlan -SearchAllSubscriptions $SearchAllSubscriptions.IsPresent -SubscriptionId $TargetSubscriptionId

    Write-Information "Searching for target App Service Plan"
    if ([String]::IsNullOrWhiteSpace($TargetResourceGroup)) {
        $TargetResourceGroup = GetResourceGroupFromPlanName -AppServicePlanName $TargetAppServicePlan
        Write-Information "Using Resource Group $TargetResourceGroup (same as app service plan $TargetAppServicePlan)"
    }
    $trgtAsp = GetAppServicePlan -AppServicePlanName $TargetAppServicePlan -ResourceGroup $TargetResourceGroup -SubscriptionId $targetSubscription.Id
    if ($null -eq $trgtAsp) {
        throw "App Service Plan $TargetAppServicePlan could not be found in Resource Group $TargetResourceGroup"
    }

    Write-Information "Create cloned SCEPman App Service"
    CreateSCEPmanAppService -SCEPmanResourceGroup $TargetResourceGroup -SCEPmanAppServiceName $TargetAppServiceName -AppServicePlanId $trgtAsp.Id

    # Service principal of System-assigned identity of cloned SCEPman
    $serviceprincipalsc = GetServicePrincipal -appServiceNameParam $TargetAppServiceName -resourceGroupParam $TargetResourceGroup

    $servicePrincipals = [System.Collections.ArrayList]@( $serviceprincipalsc.principalId )

    Write-Information "Adding permissions to Storage Account"
    if($null -ne $ScStorageAccount) {
        SetStorageAccountPermissions -SubscriptionId $targetSubscription.Id -ScStorageAccount $ScStorageAccount -servicePrincipals $servicePrincipals
    } else {
        Write-Warning "No Storage Account found. Not adding any permissions."
    }    

    Write-Information "Adding permissions to Key Vault"
    AddSCEPmanPermissionsToKeyVault -KeyVaultName $keyvaultname -PrincipalId $serviceprincipalsc.principalId

    Write-Information "Adding permissions for Graph and Intune"
    $graphResourceId = GetAzureResourceAppId -appId $MSGraphAppId
    $intuneResourceId = GetAzureResourceAppId -appId $IntuneAppId

    $resourcePermissionsForSCEPman =
        @([pscustomobject]@{'resourceId'=$graphResourceId;'appRoleId'=$MSGraphDirectoryReadAllPermission;},
        [pscustomobject]@{'resourceId'=$graphResourceId;'appRoleId'=$MSGraphDeviceManagementReadPermission;},
        [pscustomobject]@{'resourceId'=$intuneResourceId;'appRoleId'=$IntuneSCEPChallengePermission;}
    )

    $DelayForSecurityPrincipals = 3000
    Write-Verbose "Waiting for some $DelayForSecurityPrincipals milliseconds until the Security Principals are available"
    Start-Sleep -Milliseconds $DelayForSecurityPrincipals
    SetManagedIdentityPermissions -principalId $serviceprincipalsc.principalId -resourcePermissions $resourcePermissionsForSCEPman

    MarkDeploymentSlotAsConfigured -SCEPmanAppServiceName $TargetAppServiceName -SCEPmanResourceGroup $TargetResourceGroup

    Write-Information "Copying app settings from source App Service to target"
    SetAppSettings -AppServiceName $TargetAppServiceName -resourceGroup $TargetResourceGroup -Settings $SCEPmanSourceSettings.settings

    Write-Information "SCEPman cloned to App Service $TargetAppServiceName successfully"
}