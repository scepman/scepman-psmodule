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

    It 'All app roles are well-formed' {
        foreach ($appRole in ($ScepmanManifest + $CertmasterManifest)) {
            $appRole.displayName | Should -Not -BeNullOrEmpty
            $appRole.description | Should -Not -BeNullOrEmpty
            $appRole.value | Should -Not -BeNullOrEmpty
            $appRole.value | Should -Not -Match '\s' -Because "app role values must not contain whitespace ($($appRole.displayName))"
            $appRole.isEnabled | Should -BeTrue
            $appRole.allowedMemberTypes | Should -Not -BeNullOrEmpty
            foreach ($allowedMemberType in $appRole.allowedMemberTypes) {
                $allowedMemberType | Should -BeIn @('User', 'Application')
            }
        }
    }

    It 'App role values are unique within each manifest' {
        $scepmanRoleValues = $ScepmanManifest.value
        ($scepmanRoleValues | Select-Object -Unique).Count | Should -Be $scepmanRoleValues.Count

        $certmasterRoleValues = $CertmasterManifest.value
        ($certmasterRoleValues | Select-Object -Unique).Count | Should -Be $certmasterRoleValues.Count
    }

    It 'CertMaster manifest contains the self-service roles' {
        $CertmasterManifest.value | Should -Contain 'Request.User.SelfService'
        $CertmasterManifest.value | Should -Contain 'Request.User.SelfService.Csr'
        $CertmasterManifest.value | Should -Contain 'Request.User.SelfService.Form'
    }
}