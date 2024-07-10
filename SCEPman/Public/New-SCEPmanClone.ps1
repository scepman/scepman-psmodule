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

 .PARAMETER TargetVnetName
  The name of the VNET to be created for the cloned SCEPman instance. It will only be created if the source SCEPman is connected to a VNET.

 .PARAMETER TargetAppServicePlan
  The name of the App Service Plan for the cloned SCEPman instance. The App Service Plan must exist already in the TargetResourceGroup

 .Parameter TargetResourceGroup
  The Azure resource group hosting the new SCEPman App Service.

 .Parameter TargetSubscriptionId
  The ID of the Subscription where SCEPman shall be installed. Can be omitted if it is the same as SourceSubscriptionId.

 .Example
   # Create a SCEPman instance as-scepman-clone, which is a clone of the original app service as-scepman. It uses the App Service Plan asp-scepman-geo2
   New-SCEPmanClone -SourceAppServiceName as-scepman -TargetAppServiceName as-scepman-clone -TargetAppServicePlan asp-scepman-geo2 -SearchAllSubscriptions 6>&1

#>
function New-SCEPmanClone
{
    [CmdletBinding(SupportsShouldProcess=$true)]
    param(
      [Parameter(Mandatory=$true)]$SourceAppServiceName,
      $SourceResourceGroup,
      $SourceSubscriptionId,
      [Parameter(Mandatory=$true)]$TargetAppServiceName,
      [Parameter(Mandatory=$true)]$TargetAppServicePlan,
      $TargetVnetName,
      $TargetResourceGroup,
      $TargetSubscriptionId,
      [switch]$SearchAllSubscriptions,
      $GraphBaseUri = 'https://graph.microsoft.com'
      )

    $version = $MyInvocation.MyCommand.ScriptBlock.Module.Version
    Write-Verbose "Invoked $($MyInvocation.MyCommand) from SCEPman Module version $version"

    Write-Information "Installing az resource graph extension"
    az extension add --name resource-graph --only-show-errors

    Write-Information "Logging in to az"
    $null = AzLogin

    Write-Information "Getting subscription details"
    $sourceSubscription = GetSubscriptionDetails -AppServiceName $SourceAppServiceName -SearchAllSubscriptions $SearchAllSubscriptions.IsPresent -SubscriptionId $SourceSubscriptionId
    Write-Information "Source Subscription is set to $($sourceSubscription.name)"

    Write-Information "Setting source resource group"
    if ([String]::IsNullOrWhiteSpace($SourceResourceGroup)) {
        # No resource group given, search for it now
        $SourceResourceGroup = GetResourceGroup -SCEPmanAppServiceName $SourceAppServiceName
    }

    Write-Information "Checking VNET integration of SCEPman"
    $scepManVnetId = GetAppServiceVnetId -AppServiceName $SourceAppServiceName -ResourceGroup $SourceResourceGroup
    if ($null -ne $scepManVnetId) {
        Write-Information "SCEPman App Service is connected to a VNET."
    }

    Write-Information "Reading base App Service settings from source"
    $SCEPmanSourceSettings = ReadAppSettings -AppServiceName $SourceAppServiceName -resourceGroup $SourceResourceGroup

    Write-Information "Reading storage account information from source"
    $existingTableStorageEndpointSetting = GetSCEPmanStorageAccountConfig -SCEPmanResourceGroup $SourceResourceGroup -SCEPmanAppServiceName $SourceAppServiceName
    $storageAccountTableEndpoint = $existingTableStorageEndpointSetting.Trim('"')
    if(-not [string]::IsNullOrEmpty($storageAccountTableEndpoint)) {
        Write-Verbose "Storage Account Table Endpoint $storageAccountTableEndpoint found"
        $ScStorageAccount = GetExistingStorageAccount -dataTableEndpoint $storageAccountTableEndpoint
    } else {
        Write-Warning "No Storage Account found. Not adding any permissions."
    }

    Write-Information "Reading Key Vault registration from source"
    $keyvault = FindConfiguredKeyVault -SCEPmanAppServiceName $SourceAppServiceName -SCEPmanResourceGroup $SourceResourceGroup
    Write-Verbose "Key Vault $($keyvault.name) identified"

    Write-Information "Getting target subscription details"
    $targetSubscription = GetSubscriptionDetails -AppServicePlanName $TargetAppServicePlan -SearchAllSubscriptions $SearchAllSubscriptions.IsPresent -SubscriptionId $TargetSubscriptionId
    Write-Information "Target Subscription is set to $($targetSubscription.name)"

    Write-Information "Searching for target App Service Plan"
    if ([String]::IsNullOrWhiteSpace($TargetResourceGroup)) {
        $TargetResourceGroup = GetResourceGroupFromPlanName -AppServicePlanName $TargetAppServicePlan
        Write-Information "Using Resource Group $TargetResourceGroup (same as app service plan $TargetAppServicePlan)"
    }
    $trgtAsp = GetAppServicePlan -AppServicePlanName $TargetAppServicePlan -ResourceGroup $TargetResourceGroup -SubscriptionId $targetSubscription.Id
    if ($null -eq $trgtAsp) {
        throw "App Service Plan $TargetAppServicePlan could not be found in Resource Group $TargetResourceGroup"
    }

    if ($PSCmdlet.ShouldProcess($TargetAppServiceName, ("Creating SCEPman clone in Resource Group {0}" -f $TargetResourceGroup))) {
        Write-Information "Create cloned SCEPman App Service"
        CreateSCEPmanAppService -SCEPmanResourceGroup $TargetResourceGroup -SCEPmanAppServiceName $TargetAppServiceName -AppServicePlanId $trgtAsp.Id

        # Service principal of System-assigned identity of cloned SCEPman
        $serviceprincipalsc = GetServicePrincipal -appServiceNameParam $TargetAppServiceName -resourceGroupParam $TargetResourceGroup

        $servicePrincipals = [System.Collections.ArrayList]@( $serviceprincipalsc.principalId )

        Write-Information "Adding permissions to Storage Account"
        if($null -ne $ScStorageAccount) {
            SetStorageAccountPermissions -SubscriptionId $SourceSubscription.Id -ScStorageAccount $ScStorageAccount -servicePrincipals $servicePrincipals
        } else {
            Write-Warning "No Storage Account found. Not adding any permissions."
        }

        Write-Information "Adding permissions to Key Vault"
        AddSCEPmanPermissionsToKeyVault -KeyVault $keyvault -PrincipalId $serviceprincipalsc.principalId

        Write-Information "Adding permissions for Graph and Intune"
        $resourcePermissionsForSCEPman = GetSCEPmanResourcePermissions

        if ($null -ne $scepManVnetId) {
            if ($null -eq $TargetVnetName) {
                $indexOfFirstDash = $TargetAppServiceName.IndexOf("-")
                if ($indexOfFirstDash -eq -1) { # name without dashes
                    $TargetVnetName = "vnet-" + $TargetAppServiceName
                } else {
                    $TargetVnetName = "vnet-" + $TargetAppServiceName.Substring($indexOfFirstDash + 1)
                }
                if ($TargetVnetName.Length -gt 64) {
                    $TargetVnetName = $TargetVnetName.Substring(0, 64)
                }
            }
            Write-Information "Creating VNET $TargetVnetName for Clone"
            $subnet = New-Vnet -ResourceGroupName $TargetResourceGroup -VnetName $TargetVnetName -SubnetName "sub-scepman" -Location $trgtAsp.Location -StorageAccountLocation $ScStorageAccount.Location
            SetAppServiceVnetId -AppServiceName $TargetAppServiceName -ResourceGroup $TargetResourceGroup -VnetId $subnet.id
            Write-Information "Allowing access to Key Vault and Storage Account from the clone's new VNET"
            Grant-VnetAccessToKeyVault -KeyVaultName $keyvault.name -SubnetId $subnet.id -SubscriptionId $SourceSubscription.Id
            Grant-VnetAccessToStorageAccount -ScStorageAccount $ScStorageAccount -SubnetId $subnet.id -SubscriptionId $SourceSubscription.Id
        }

        $DelayForSecurityPrincipals = 3000
        Write-Verbose "Waiting for $DelayForSecurityPrincipals milliseconds until the Security Principals are available"
        Start-Sleep -Milliseconds $DelayForSecurityPrincipals
        $permissionLevelScepman = SetManagedIdentityPermissions -principalId $serviceprincipalsc.principalId -resourcePermissions $resourcePermissionsForSCEPman -GraphBaseUri $GraphBaseUri

        Write-Information "Copying app settings from source App Service to target"
        SetAppSettings -AppServiceName $TargetAppServiceName -resourceGroup $TargetResourceGroup -Settings $SCEPmanSourceSettings.settings

        MarkDeploymentSlotAsConfigured -SCEPmanAppServiceName $TargetAppServiceName -SCEPmanResourceGroup $TargetResourceGroup -PermissionLevel $permissionLevelScepman

        Write-Information "SCEPman cloned to App Service $TargetAppServiceName successfully"
    }
}