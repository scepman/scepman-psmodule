BeforeAll {
    . $PSScriptRoot/../SCEPman/Private/constants.ps1
    . $PSScriptRoot/../SCEPman/Private/az-commands.ps1
    . $PSScriptRoot/../SCEPman/Private/app-service.ps1
    . $PSScriptRoot/../SCEPman/Private/storage-account.ps1
    . $PSScriptRoot/../SCEPman/Private/subscriptions.ps1
    . $PSScriptRoot/../SCEPman/Private/permissions.ps1
    . $PSScriptRoot/../SCEPman/Public/New-SCEPmanClone.ps1

    . $PSScriptRoot/test-helpers.ps1
}

Describe 'SCEPman Clone' {
    It 'creates a new clone' {
        # Arrange
        MockAzInitals
            # Arrange reading the existing SCEPman
        Mock GetResourceGroup {
            return "rg-scepman"
        } -ParameterFilter { $SCEPmanAppServiceName -eq "as-scepman" }
        Mock GetAppServiceVnetId {
            return $null
        }
        $TestScepmanSourceSettings = @{
            "AppConfig:KeyVaultConfig:KeyVaultURL" = "https://test.vault.azure.net"
            "AppConfig:KeyVaultConfig:RootCertificateConfig:CertificateName" = "test-certificate"
        }
        Mock ReadAppSettings {
            return @{
                settings = $TestScepmanSourceSettings
                unboundSettings = @{
                    "AppConfig:AuthConfig:ManagedIdentityPermissionLevel" = '8'
                }
            }
        } -ParameterFilter { $AppServiceName -eq "as-scepman" -and $ResourceGroup -eq "rg-scepman" }
        Mock ReadAppSetting {
            return '"storage-account-endpoint"'
        } -ParameterFilter { $AppServiceName -eq "as-scepman" -and $ResourceGroup -eq "rg-scepman" -and $SettingName -eq "AppConfig:CertificateStorage:TableStorageEndpoint" }
        Mock GetExistingStorageAccount {
            return "storage-account-endpoint-value"
        } -ParameterFilter { $dataTableEndpoint -eq "storage-account-endpoint" }
        function FindConfiguredKeyVault ($SCEPmanResourceGroup, $SCEPmanAppServiceName) {} # Mocked
        Mock FindConfiguredKeyVault {
            return @{
                name = "test-kv-name"
            }
        } -ParameterFilter { $SCEPmanAppServiceName -eq "as-scepman" -and $SCEPmanResourceGroup -eq "rg-scepman" }

            # Arrange finding the target
        Mock GetSubscriptionDetails {
            return @{
                name = "target-subscription"
                tenantId = "test-tenant"
                id = "87654321-1234-1234-aaaabbbbcccc"
            }
        } -ParameterFilter { $AppServicePlanName -eq "asp-scepman-geo2" -and $null -eq $AppServiceName }
        Mock GetResourceGroupFromPlanName {
            return "rg-scepman-geo2"
        } -ParameterFilter { $AppServicePlanName -eq "asp-scepman-geo2" }
        $mockedAppServicePlanId = "/subscriptions/test-subscription/resourceGroups/rg-scepman-geo2/providers/Microsoft.Web/serverfarms/asp-scepman-geo2"
        Mock GetAppServicePlan {
            return @{
                name = "asp-scepman-geo2"
                resourceGroup = "rg-scepman-geo2"
                id = $mockedAppServicePlanId
            }
        } -ParameterFilter { $AppServicePlanName -eq "asp-scepman-geo2" }
        
            # Arrange creating the new SCEPman
        Mock CreateSCEPmanAppService {
        } -ParameterFilter { $SCEPmanAppServiceName -eq "as-scepman-clone" -and $SCEPmanResourceGroup -eq "rg-scepman-geo2" -and $AppServicePlanId -eq $mockedAppServicePlanId }
        Mock GetServicePrincipal {
            return @{
                principalId = "ea63b5f9-3fb8-4494-a83b-9cb7d3e48793"
            }
        } -ParameterFilter { $appServiceNameParam -eq "as-scepman-clone" -and $resourceGroupParam -eq "rg-scepman-geo2" } -Verifiable
        Mock SetStorageAccountPermissions {
        } -ParameterFilter { $SubscriptionId -eq "12345678-1234-1234-aaaabbbbcccc" -and $ScStorageAccount -eq "storage-account-endpoint-value" -and $servicePrincipals.Contains("ea63b5f9-3fb8-4494-a83b-9cb7d3e48793") } -Verifiable
        function AddSCEPmanPermissionsToKeyVault ($KeyVault, $PrincipalId) { } # Mocked
        Mock AddSCEPmanPermissionsToKeyVault {
        } -ParameterFilter { $KeyVault.name -eq "test-kv-name" -and $PrincipalId -eq "ea63b5f9-3fb8-4494-a83b-9cb7d3e48793" } -Verifiable
        Mock GetAzureResourceAppId {
            return $appId   # Just for the test
        } # Will be called twice, once for Graph, once for Intune
        function CheckResourcePermissions ($resourcePermissions) {
            $graphPermissions = $resourcePermissions | Where-Object { $_.resourceId -eq $MSGraphAppId } # Checking for the resourceId for App Id is a hack, it works just in this mock, not in reality
            if ($graphPermissions.count -ne 4) {    # we expect four graph permissions
                return $false
            }
            $intunePermissions = $resourcePermissions | Where-Object { $_.resourceId -eq $IntuneAppId } # Checking for the resourceId for App Id is a hack, it works just in this mock, not in reality
            if ($intunePermissions.count -ne 1) {    # we expect one intune permission (SCEP Challenge)
                return $false
            }
            return $true
        }
        Mock SetManagedIdentityPermissions {
        } -ParameterFilter { $PrincipalId -eq "ea63b5f9-3fb8-4494-a83b-9cb7d3e48793" -and (CheckResourcePermissions $resourcePermissions) } -Verifiable
        Mock SetAppSettings {
        } -ParameterFilter { $AppServiceName -eq "as-scepman-clone" -and $ResourceGroup -eq "rg-scepman-geo2" -and $Settings -eq $TestScepmanSourceSettings } -Verifiable
        Mock MarkDeploymentSlotAsConfigured {
        } -ParameterFilter { $SCEPmanAppServiceName -eq "as-scepman-clone" -and $SCEPmanResourceGroup -eq "rg-scepman-geo2" } -Verifiable

        # Act
        New-SCEPmanClone -SourceAppServiceName as-scepman -TargetAppServiceName as-scepman-clone -TargetAppServicePlan asp-scepman-geo2 -SearchAllSubscriptions 6>&1

        # Assert
        CheckAzInitials
        Should -Invoke GetResourceGroup -Exactly 1
        Should -Invoke GetAppServiceVnetId -Exactly 1
        Should -Invoke ReadAppSettings -Exactly 1

        Should -Invoke GetSubscriptionDetails -Exactly 1 -ParameterFilter { $AppServicePlanName -eq "asp-scepman-geo2" -and $null -eq $AppServiceName }
        Should -Invoke GetResourceGroupFromPlanName -Exactly 1
        Should -Invoke GetAppServicePlan -Exactly 1

        Should -Invoke CreateSCEPmanAppService -Exactly 1 -ParameterFilter { $SCEPmanAppServiceName -eq "as-scepman-clone" -and $SCEPmanResourceGroup -eq "rg-scepman-geo2" -and $AppServicePlanId -eq $mockedAppServicePlanId }

        Should -InvokeVerifiable    # Pester doesn't allow to pass in counts for Should -InvokeVerifiable
    }
}