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
   New-SCEPmanDeploymentSlot -SCEPmanAppServiceName as-scepman -DeploymentSlotName pre-release

#>
function New-SCEPmanDeploymentSlot
{
    [CmdletBinding(SupportsShouldProcess=$true)]
    param(
      $SCEPmanAppServiceName,
      $SCEPmanResourceGroup,
      [switch]$SearchAllSubscriptions,
      [Parameter(Mandatory=$true)]$DeploymentSlotName,
      $SubscriptionId,
      $GraphBaseUri = 'https://graph.microsoft.com'
    )

    $version = $MyInvocation.MyCommand.ScriptBlock.Module.Version
    Write-Verbose "Invoked $($MyInvocation.MyCommand) from SCEPman Module version $version"

    if ([String]::IsNullOrWhiteSpace($SCEPmanAppServiceName)) {
        $SCEPmanAppServiceName = Read-Host "Please enter the SCEPman app service name"
    }

    Write-Information "Installing az resource graph extension"
    az extension add --name resource-graph --only-show-errors

    Write-Information "Adding SCEPman Deployment Slot $DeploymentSlotName"

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

    Write-Information "Getting existing SCEPman deployment slots"
    $deploymentSlotsSc = GetDeploymentSlots -appServiceName $SCEPmanAppServiceName -resourceGroup $SCEPmanResourceGroup
    Write-Information "$($deploymentSlotsSc.Count) deployment slots found"

    if (($deploymentSlotsSc | Where-Object { $_ -eq $DeploymentSlotName }).Count -gt 0) {
        Write-Error "Deployment slot $DeploymentSlotName already exists. Aborting ..."
        throw "Deployment slot $DeploymentSlotName already exists."
    }

    Write-Information "Checking VNET integration of SCEPman"
    $scepManVnetId = GetAppServiceVnetId -AppServiceName $SCEPmanAppServiceName -ResourceGroup $SCEPmanResourceGroup
    if ($null -ne $scepManVnetId) {
        Write-Information "SCEPman App Service is connected to VNET $ScepManVnetId. The Deployment Slot will inherit this configuration."
    }

    if ($PSCmdlet.ShouldProcess($DeploymentSlotName, "Creating SCEPman Deployment Slot")) {
        Write-Information "Creating new Deployment Slot $DeploymentSlotName"
        # Returns the Service principal of the deployment slot
        $serviceprincipalsc = CreateSCEPmanDeploymentSlot -SCEPmanAppServiceName $SCEPmanAppServiceName -SCEPmanResourceGroup $SCEPmanResourceGroup -DeploymentSlotName $DeploymentSlotName
        $servicePrincipals = @( $serviceprincipalsc.principalId )
        Write-Debug "Created SCEPman Deployment Slot has Managed Identity Principal $serviceprincipalsc"
    }

    if ($PSCmdlet.ShouldProcess($scepManVnetId, "Adding VNET integration to new deployment slot")) {
        Write-Information "Adding VNET integration to new Deployment Slot"
        SetAppServiceVnetId -AppServiceName $SCEPmanAppServiceName -ResourceGroup $SCEPmanResourceGroup -VnetId $scepManVnetId -DeploymentSlotName $DeploymentSlotName
    }

    if ($PSCmdlet.ShouldProcess($ScSDeploymentSlotNametorageAccount, "Adding storage account permissions to new deployment slot")) {
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
    }

    Write-Information "Adding permissions to Key Vault"
    $keyvault = FindConfiguredKeyVault -SCEPmanAppServiceName $SCEPmanAppServiceName -SCEPmanResourceGroup $SCEPmanResourceGroup
    Write-Verbose "Key Vault $keyvaultname identified"
    if ($PSCmdlet.ShouldProcess($keyvault.name, "Adding key vault permissions to new deployment slot")) {
        AddSCEPmanPermissionsToKeyVault -KeyVault $keyvault -PrincipalId $serviceprincipalsc.principalId
    }

    Write-Information "Adding permissions for Graph and Intune"
    $resourcePermissionsForSCEPman = GetSCEPmanResourcePermissions

    $DelayForSecurityPrincipals = 3000
    Write-Verbose "Waiting for some $DelayForSecurityPrincipals milliseconds until the Security Principals are available"
    Start-Sleep -Milliseconds $DelayForSecurityPrincipals
    if ($PSCmdlet.ShouldProcess($DeploymentSlotName, "Adding permissions for new deployment slot to access Microsoft Graph")) {
        $null = SetManagedIdentityPermissions -principalId $serviceprincipalsc.principalId -resourcePermissions $resourcePermissionsForSCEPman -GraphBaseUri $GraphBaseUri
        MarkDeploymentSlotAsConfigured -SCEPmanAppServiceName $SCEPmanAppServiceName -DeploymentSlotName $DeploymentSlotName -SCEPmanResourceGroup $SCEPmanResourceGroup
    }

    Write-Information "SCEPman Deployment Slot $DeploymentSlotName successfully created"
}