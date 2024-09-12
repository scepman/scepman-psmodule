BeforeAll {
    . $PSScriptRoot/../SCEPman/Private/constants.ps1
    . $PSScriptRoot/../SCEPman/Private/az-commands.ps1
    . $PSScriptRoot/../SCEPman/Private/app-service.ps1
    . $PSScriptRoot/../SCEPman/Private/storage-account.ps1
    . $PSScriptRoot/../SCEPman/Private/subscriptions.ps1
    . $PSScriptRoot/../SCEPman/Private/permissions.ps1
    . $PSScriptRoot/../SCEPman/Private/vnet.ps1
    . $PSScriptRoot/../SCEPman/Public/New-SCEPmanClone.ps1

    . $PSScriptRoot/test-helpers.ps1

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
}

Describe 'SCEPman Clone' {
    BeforeAll {
        $TestScepmanSourceSettings = @{
            "AppConfig:KeyVaultConfig:KeyVaultURL" = "https://test.vault.azure.net"
            "AppConfig:KeyVaultConfig:RootCertificateConfig:CertificateName" = "test-certificate"
        }

        function MockFindingATarget {
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
                    Location = "germanywestcentral"
                }
            } -ParameterFilter { $AppServicePlanName -eq "asp-scepman-geo2" }
        }

        function AssertFindingATarget {
            Should -Invoke GetSubscriptionDetails -Exactly 1 -ParameterFilter { $AppServicePlanName -eq "asp-scepman-geo2" -and $null -eq $AppServiceName }
            Should -Invoke GetResourceGroupFromPlanName -Exactly 1
            Should -Invoke GetAppServicePlan -Exactly 1
        }

        function MockScepmanCreation {
            # Arrange creating the new SCEPman
            Mock CreateSCEPmanAppService {
            } -ParameterFilter { $SCEPmanAppServiceName -eq "as-scepman-clone" -and $SCEPmanResourceGroup -eq "rg-scepman-geo2" -and $AppServicePlanId -eq $mockedAppServicePlanId }
            Mock GetServicePrincipal {
                return @{
                    principalId = "ea63b5f9-3fb8-4494-a83b-9cb7d3e48793"
                }
            } -ParameterFilter { $appServiceNameParam -eq "as-scepman-clone" -and $resourceGroupParam -eq "rg-scepman-geo2" }
            Mock SetStorageAccountPermissions {
            } -ParameterFilter { $SubscriptionId -eq "12345678-1234-1234-aaaabbbbcccc" -and $ScStorageAccount.name -eq "stgxyztest" -and $servicePrincipals.Contains("ea63b5f9-3fb8-4494-a83b-9cb7d3e48793") }
            function AddSCEPmanPermissionsToKeyVault ($KeyVault, $PrincipalId) { } # Mocked
            Mock AddSCEPmanPermissionsToKeyVault {
            } -ParameterFilter { $KeyVault.name -eq "test-kv-name" -and $PrincipalId -eq "ea63b5f9-3fb8-4494-a83b-9cb7d3e48793" }
            Mock GetAzureResourceAppId {
                return $appId   # Just for the test
            } # Will be called twice, once for Graph, once for Intune
            Mock SetManagedIdentityPermissions {
            } -ParameterFilter { $PrincipalId -eq "ea63b5f9-3fb8-4494-a83b-9cb7d3e48793" -and (CheckResourcePermissions $resourcePermissions) }
            Mock SetAppSettings {
            } -ParameterFilter { $AppServiceName -eq "as-scepman-clone" -and $ResourceGroup -eq "rg-scepman-geo2" -and $Settings -eq $TestScepmanSourceSettings }
            Mock MarkDeploymentSlotAsConfigured {
            } -ParameterFilter { $SCEPmanAppServiceName -eq "as-scepman-clone" -and $SCEPmanResourceGroup -eq "rg-scepman-geo2" }
        }

        function AssertScepmanCreation {
            Should -Invoke CreateSCEPmanAppService -Exactly 1 -ParameterFilter { $SCEPmanAppServiceName -eq "as-scepman-clone" -and $SCEPmanResourceGroup -eq "rg-scepman-geo2" -and $AppServicePlanId -eq $mockedAppServicePlanId }
            Should -Invoke GetServicePrincipal -Exactly 1 -ParameterFilter { $appServiceNameParam -eq "as-scepman-clone" -and $resourceGroupParam -eq "rg-scepman-geo2" }
            Should -Invoke SetStorageAccountPermissions -Exactly 1 -ParameterFilter { $SubscriptionId -eq "12345678-1234-1234-aaaabbbbcccc" -and $ScStorageAccount.name -eq "stgxyztest" -and $servicePrincipals.Contains("ea63b5f9-3fb8-4494-a83b-9cb7d3e48793") }
            Should -Invoke AddSCEPmanPermissionsToKeyVault -Exactly 1 -ParameterFilter { $KeyVault.name -eq "test-kv-name" -and $PrincipalId -eq "ea63b5f9-3fb8-4494-a83b-9cb7d3e48793" }
            Should -Invoke GetAzureResourceAppId -Exactly 2
            Should -Invoke SetManagedIdentityPermissions -Exactly 1 -ParameterFilter { $PrincipalId -eq "ea63b5f9-3fb8-4494-a83b-9cb7d3e48793" -and (CheckResourcePermissions $resourcePermissions) }
            Should -Invoke SetAppSettings -Exactly 1 -ParameterFilter { $AppServiceName -eq "as-scepman-clone" -and $ResourceGroup -eq "rg-scepman-geo2" -and $Settings -eq $TestScepmanSourceSettings }
            Should -Invoke MarkDeploymentSlotAsConfigured -Exactly 1 -ParameterFilter { $SCEPmanAppServiceName -eq "as-scepman-clone" -and $SCEPmanResourceGroup -eq "rg-scepman-geo2" }
        }

        function MockReadExistingScepmanBasics {
            Mock GetResourceGroup {
                return "rg-scepman"
            } -ParameterFilter { $SCEPmanAppServiceName -eq "as-scepman" }
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
                return @{
                    name = "stgxyztest"
                    location = "germanywestcentral"
                    resourceGroup = "rg-xyz-test"
                    # Some more are returned in reality
                }
            } -ParameterFilter { $dataTableEndpoint -eq "storage-account-endpoint" }
            function FindConfiguredKeyVault ($SCEPmanResourceGroup, $SCEPmanAppServiceName) {} # Mocked
            Mock FindConfiguredKeyVault {
                return @{
                    name = "test-kv-name"
                }
            } -ParameterFilter { $SCEPmanAppServiceName -eq "as-scepman" -and $SCEPmanResourceGroup -eq "rg-scepman" }
        }

        function AssertReadExistingScepmanBasics {
            Should -Invoke GetResourceGroup -Exactly 1
            Should -Invoke ReadAppSettings -Exactly 1
        }

        function MockGetVnetId ($idToReturn) {
            Mock az {
                return $idToReturn
            } -ParameterFilter { CheckAzParameters -argsFromCommand $args -azCommandPrefix "webapp show" -azCommandMidfix "--query virtualNetworkSubnetId " }
        }

        function AssertGetVnetId {
            Should -Invoke az -Exactly 1 -ParameterFilter { CheckAzParameters -argsFromCommand $args -azCommandPrefix "webapp show" -azCommandMidfix "--query virtualNetworkSubnetId " }
        }

        function MockVnetCreation {
            $mockedVnetId ="/subscriptions/test-subscription/resourceGroups/rg-scepman-geo2/providers/Microsoft.Network/virtualNetworks/vnet-as-scepman-clone/subnets/sub-scepman"
            Mock New-Vnet {
                return @{
                    id = $mockedVnetId
                }
            } -ParameterFilter { $ResourceGroupName -eq "rg-scepman-geo2" -and $VnetName -eq "vnet-as-scepman-clone" -and $SubnetName -eq "sub-scepman" -and $Location -eq "germanywestcentral" -and $StorageAccountLocation -eq "germanywestcentral" }
            Mock SetAppServiceVnetId {
            } -ParameterFilter { $AppServiceName -eq "as-scepman-clone" -and $ResourceGroup -eq "rg-scepman-geo2" -and $VnetId -eq $mockedVnetId }
            function Grant-VnetAccessToKeyVault ($KeyVaultName, $SubnetId, $SubscriptionId) {} # Mocked
            Mock Grant-VnetAccessToKeyVault {
            } -ParameterFilter { $KeyVaultName -eq "test-kv-name" -and $SubnetId -eq $mockedVnetId -and $SubscriptionId -eq "12345678-1234-1234-aaaabbbbcccc" }
            Mock Grant-VnetAccessToStorageAccount {
            } -ParameterFilter { $ScStorageAccount.name -eq "stgxyztest" -and $SubnetId -eq $mockedVnetId -and $SubscriptionId -eq "12345678-1234-1234-aaaabbbbcccc" }
        }

        function AssertVnetCreation {
            Should -Invoke New-Vnet -Exactly 1 -ParameterFilter { $ResourceGroupName -eq "rg-scepman-geo2" -and $VnetName -eq "vnet-as-scepman-clone" -and $SubnetName -eq "sub-scepman" -and $Location -eq "germanywestcentral" -and $StorageAccountLocation -eq "germanywestcentral" }
            Should -Invoke SetAppServiceVnetId -Exactly 1 -ParameterFilter { $AppServiceName -eq "as-scepman-clone" -and $ResourceGroup -eq "rg-scepman-geo2" -and $VnetId -eq "/subscriptions/test-subscription/resourceGroups/rg-scepman-geo2/providers/Microsoft.Network/virtualNetworks/vnet-as-scepman-clone/subnets/sub-scepman" }
            Should -Invoke Grant-VnetAccessToKeyVault -Exactly 1 -ParameterFilter { $KeyVaultName -eq "test-kv-name" -and $SubnetId -eq "/subscriptions/test-subscription/resourceGroups/rg-scepman-geo2/providers/Microsoft.Network/virtualNetworks/vnet-as-scepman-clone/subnets/sub-scepman" -and $SubscriptionId -eq "12345678-1234-1234-aaaabbbbcccc" }
            Should -Invoke Grant-VnetAccessToStorageAccount -Exactly 1 -ParameterFilter { $ScStorageAccount.name -eq "stgxyztest" -and $SubnetId -eq "/subscriptions/test-subscription/resourceGroups/rg-scepman-geo2/providers/Microsoft.Network/virtualNetworks/vnet-as-scepman-clone/subnets/sub-scepman" -and $SubscriptionId -eq "12345678-1234-1234-aaaabbbbcccc" }
        }
    }

    It 'creates a new clone without VNET' {
        # Arrange
        MockAzInitals
        MockReadExistingScepmanBasics
        MockGetVnetId $null
        MockFindingATarget
        MockScepmanCreation

        # Act
        New-SCEPmanClone -SourceAppServiceName as-scepman -TargetAppServiceName as-scepman-clone -TargetAppServicePlan asp-scepman-geo2 -SearchAllSubscriptions 6>&1

        # Assert
        CheckAzInitials
        AssertReadExistingScepmanBasics
        AssertGetVnetId
        AssertFindingATarget
        AssertScepmanCreation
    }

    It 'creates a new clone with VNET' {
        # Arrange
        MockAzInitals
        MockReadExistingScepmanBasics
        MockGetVnetId -idToReturn "this-is-the-vnetid"
        MockFindingATarget
        MockScepmanCreation
        MockVnetCreation

        # Act
        New-SCEPmanClone -SourceAppServiceName as-scepman -TargetAppServiceName as-scepman-clone -TargetAppServicePlan asp-scepman-geo2 -SearchAllSubscriptions 6>&1

        # Assert
        CheckAzInitials
        AssertReadExistingScepmanBasics
        AssertGetVnetId
        AssertFindingATarget
        AssertScepmanCreation
        AssertVnetCreation
    }
}