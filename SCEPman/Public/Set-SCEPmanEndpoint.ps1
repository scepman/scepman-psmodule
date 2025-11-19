Function Set-SCEPmanEndpoint {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$SCEPmanAppServiceName,
        [string]$DeploymentSlotName,
        [string]$SCEPmanResourceGroupName,

        [Parameter(Mandatory)]
        [ValidateSet("ActiveDirectory")]
        [string]$Endpoint,

        # AD Endpoint specific parameters
        [string]$EncryptedKeyTab,
        [string]$EncryptedPassword,
        [string]$GroupFilter,
        [switch]$EnableUser,
        [switch]$EnableComputer,
        [switch]$EnableDC,

        [string]$SubscriptionId,
        [switch]$SearchAllSubscriptions
    )

    Begin {
        if(-not $PSBoundParameters.ContainsKey('InformationAction')) {
            Write-Debug "Setting InformationAction to 'Continue' for this cmdlet as no user preference was set."
            $InformationPreference = 'Continue'
        }

        $version = $MyInvocation.MyCommand.ScriptBlock.Module.Version
        Write-Verbose "Invoked $($MyInvocation.MyCommand)"
        Write-Information "SCEPman Module version $version on PowerShell $($PSVersionTable.PSVersion)"

        $cliVersion = [Version]::Parse((GetAzVersion).'azure-cli')
        Write-Information "Detected az version: $cliVersion"

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

        Write-Information "Getting SCEPman deployment slots"
        [array]$deploymentSlotsSc = GetDeploymentSlots -appServiceName $SCEPmanAppServiceName -resourceGroup $SCEPmanResourceGroup
        Write-Information "$($deploymentSlotsSc.Count) deployment slots found"

        if ($DeploymentSlotName) {
            if (($deploymentSlotsSc | Where-Object { $_ -eq $DeploymentSlotName }).Count -gt 0) {
                Write-Information "Updating only deployment slot $DeploymentSlotName"
                $deploymentSlotsSc = @($DeploymentSlotName)
            } else {
                Write-Error "Only $DeploymentSlotName should be updated, but it was not found among the deployment slots: $([string]::join($deploymentSlotsSc))"
                throw "Only $DeploymentSlotName should be updated, but it was not found"
            }
        }
    }

    Process {
        If($Endpoint -eq "ActiveDirectory") {
            Write-Information "Configuring AD endpoint"

            $EndpointSettings = @(
                @{ Name = "AppConfig:ActiveDirectory:Enabled"; Value = 'true' }
            )

            if ($EncryptedKeyTab) { $EndpointSettings += @{ Name = "AppConfig:ActiveDirectory:KeyTab"; Value = $EncryptedKeyTab } }
            if ($EncryptedPassword) { $EndpointSettings += @{ Name = "AppConfig:ActiveDirectory:EncryptedPassword"; Value = $EncryptedPassword } }
            if ($GroupFilter) { $EndpointSettings += @{ Name = "AppConfig:ActiveDirectory:GroupFilter"; Value = $GroupFilter } }

            if ($EnableUser) { $EndpointSettings += @{ Name = "AppConfig:ActiveDirectory:User:Enabled"; Value = 'true' } }
            if ($EnableComputer) { $EndpointSettings += @{ Name = "AppConfig:ActiveDirectory:Computer:Enabled"; Value = 'true' } }
            if ($EnableDC) { $EndpointSettings += @{ Name = "AppConfig:ActiveDirectory:DC:Enabled"; Value = 'true' } }
        }

        $SetAppSettingsParameters = @{
            AppServiceName = $SCEPmanAppServiceName
            resourceGroup  = $SCEPmanResourceGroup
            Settings       = $EndpointSettings
        }

        if ($DeploymentSlotName) { $SetAppSettingsParameters.DeploymentSlotName = $DeploymentSlotName }

        SetAppSettings @SetAppSettingsParameters
    }
}