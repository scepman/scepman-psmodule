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

        It 'Should succeed if az account show returns a warning line before JSON' {
            # Arrange
            mock az {
                Write-Error 'C:\Users\userx\.azure\cliextensions\azure-devops\azext_devops\dev\__init__.py:5: UserWarning: pkg_resources is deprecated as an API. See https://setuptools.pypa.io/en/latest/pkg_resources.html. The pkg_resources package is slated for removal as early as 2025-11-30. Refrain from using this package or pin to Setuptools<81.'
                Write-Error '  import pkg_resources'
                return @(
                    '{ "user": { "name": "testuser" } }'
                )
            } -ParameterFilter { CheckAzParameters -argsFromCommand $args -azCommandPrefix 'account show' }
            EnsureNoAdditionalAzCalls

            # Act
            $account = AzLogin

            # Assert
            $account.user.name | Should -Be "testuser"
        }
    }
}