BeforeAll {
    . $PSScriptRoot/../SCEPman/Private/az-commands.ps1

    . $PSScriptRoot/test-helpers.ps1
}

Describe 'az-commands' {
    It 'Should find that this test does not run in Azure Cloud Shell' {
        $isAzureCloudShell = IsAzureCloudShell
        $isAzureCloudShell | Should -Be $false
    }

    It 'Should leave plain az arguments unquoted when formatting commands for display' {
        $command = @('rest', '--method', 'post', '--resource-group', 'rg-scepman-01')

        $formattedCommand = Format-AzCommandForDisplay -azCommand $command

        $formattedCommand | Should -Be 'rest --method post --resource-group rg-scepman-01'
    }

    It 'Should quote only az arguments that likely need escaping when formatting commands for display' {
        $command = @('role', 'assignment', 'create', '--role', 'Monitoring Metrics Publisher', '--headers', 'Content-Type=application/json', '--scope', '/subscriptions/test/resourceGroups/rg scepman', '--body', '{"key":"value with spaces"}')

        $formattedCommand = Format-AzCommandForDisplay -azCommand $command

        $formattedCommand | Should -Be 'role assignment create --role "Monitoring Metrics Publisher" --headers "Content-Type=application/json" --scope "/subscriptions/test/resourceGroups/rg scepman" --body "{`"key`":`"value with spaces`"}"'
    }

    It 'Should escape backticks and quotes when formatting commands for display' {
        $command = @('--body', 'a `b "c"')

        $formattedCommand = Format-AzCommandForDisplay -azCommand $command

        $formattedCommand | Should -Be '--body "a ``b `"c`""'
    }

    Context 'AzLogin' {
        BeforeAll {
            # Arrange
            $script:PreviousErrorActionPreference = $ErrorActionPreference
            $ErrorActionPreference = 'Continue'
            EnsureNoAdditionalAzCalls
        }

        AfterAll {
            # Restore the original ErrorActionPreference
            $ErrorActionPreference = $script:PreviousErrorActionPreference
        }

        It 'Should succeed if already logged in' {
            # Arrange
            mock az { return '{ "user": { "name": "testuser" } }' } -ParameterFilter { CheckAzParameters -argsFromCommand $args -azCommandPrefix 'account show' }

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

            # Act
            $account = AzLogin

            # Assert
            $account.user.name | Should -Be "testuser"
        }

        It 'Should succeed if az account show returns MGMT_DEPLOYMENTMANAGER error before JSON' {
            # Arrange
            mock az {
                Write-Error 'ERROR: blahblah MGMT_DEPLOYMENTMANAGER'   # I don't recall the actual error message, but it is something like this
                return @(
                    '{ "user": { "name": "testuser" } }'
                )
            } -ParameterFilter { CheckAzParameters -argsFromCommand $args -azCommandPrefix 'account show' }

            # Act
            $account = AzLogin

            # Assert
            $account.user.name | Should -Be "testuser"
        }

        It 'Should log in when not logged in' {
            # Arrange
            $script:loggedInAlready = $false
            mock az {
                if ($script:loggedInAlready) {
                    return '{ "user": { "name": "testuser" } }'
                }
                else {
                    Write-Error "Please run 'az login' to setup account."
                }
            } -ParameterFilter { CheckAzParameters -argsFromCommand $args -azCommandPrefix 'account show' }
            mock az {
                $script:loggedInAlready = $true
                return '{ "user": { "name": "testuser" } }'
            } -ParameterFilter { CheckAzParameters -argsFromCommand $args -azCommandPrefix 'login' }

            # Act
            $account = AzLogin

            # Assert
            $account.user.name | Should -Be "testuser"
        }
    }
}