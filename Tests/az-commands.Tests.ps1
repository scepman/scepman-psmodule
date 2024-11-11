BeforeAll {
    . $PSScriptRoot/../SCEPman/Private/az-commands.ps1

    . $PSScriptRoot/test-helpers.ps1
}

Describe 'az-commands' {
    It 'Should find that this test does not run in Azure Cloud Shell' {
        $isAzureCloudShell = IsAzureCloudShell
        $isAzureCloudShell | Should -Be $false
    }

    Context 'AzLogin' {
        It 'Should succeed if already logged in' {
            # Arrange
            mock az { return '{ "user": { "name": "testuser" } }' } -ParameterFilter { CheckAzParameters -argsFromCommand $args -azCommandPrefix 'account show' }
            EnsureNoAdditionalAzCalls

            # Act
            $account = AzLogin

            # Assert
            $account.user.name | Should -Be "testuser"
        }
    }
}