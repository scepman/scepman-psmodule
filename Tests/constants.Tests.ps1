BeforeAll {
    . $PSScriptRoot/../SCEPman/Private/constants.ps1
}

Describe 'Constants' {
    It 'Permission IDs should be Guids' {
        $MSGraphUserReadPermission | Should -Match "^\{?[a-fA-F\d]{8}-([a-fA-F\d]{4}-){3}[a-fA-F\d]{12}\}?$"
        $MSGraphDirectoryReadAllPermission | Should -Match "^\{?[a-fA-F\d]{8}-([a-fA-F\d]{4}-){3}[a-fA-F\d]{12}\}?$"
        $MSGraphDeviceManagementReadPermission | Should -Match "^\{?[a-fA-F\d]{8}-([a-fA-F\d]{4}-){3}[a-fA-F\d]{12}\}?$"
        $MSGraphDeviceManagementConfigurationReadAll | Should -Match "^\{?[a-fA-F\d]{8}-([a-fA-F\d]{4}-){3}[a-fA-F\d]{12}\}?$"
        $MSGraphIdentityRiskyUserReadPermission | Should -Match "^\{?[a-fA-F\d]{8}-([a-fA-F\d]{4}-){3}[a-fA-F\d]{12}\}?$"
        $IntuneSCEPChallengePermission | Should -Match "^\{?[a-fA-F\d]{8}-([a-fA-F\d]{4}-){3}[a-fA-F\d]{12}\}?$"
    }

    It 'Manifests should be an array of objects' {
        $ScepmanManifest.GetType().Name | Should -BeExactly "Object[]"
        $CertmasterManifest.GetType().Name | Should -BeExactly "Object[]"
    }
}