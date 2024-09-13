BeforeAll {
    . $PSScriptRoot/../SCEPman/Private/constants.ps1
    . $PSScriptRoot/../SCEPman/Private/az-commands.ps1
    . $PSScriptRoot/../SCEPman/Private/permissions.ps1
    . $PSScriptRoot/../SCEPman/Private/appregistrations.ps1
    . $PSScriptRoot/../SCEPman/Public/Register-SCEPmanApiClient.ps1

    . $PSScriptRoot/test-helpers.ps1
}

Describe "Register-SCEPmanApiClient" {
    BeforeEach {
        MockAzInitals -findSubscription $false
    }

    AfterEach {
        CheckAzInitials -findSubscription $false
    }

    BeforeAll {
        Mock az {
            throw "Unexpected parameter for az: $args (with array values $($args[0]), $($args[1]), ... -- #$($args.Count) in total)"
        }
    }

    It "Registers the SCEPman API Client" {
        # Arrange
        Mock az {
            return Get-Content -Path "./Tests/Data/appregistration-without-az.json"
        } -ParameterFilter { CheckAzParameters -argsFromCommand $args -azCommandPrefix "ad app list" -azCommandMidfix "displayname eq 'SCEPman-api'" }
        Mock CreateServicePrincipal {
            return "33335678-aad6-4711-82a9-0123456789ab"
        }
        Mock SetManagedIdentityPermissions {
        } -ParameterFilter { $principalId -eq "12345678-aad6-4711-82a9-0123456789ab" -and $resourcePermissions.resourceId -eq "33335678-aad6-4711-82a9-0123456789ab" }

        # Act
        Register-SCEPmanApiClient -ServicePrincipalId "12345678-aad6-4711-82a9-0123456789ab"

        # Assert
        Should -Invoke az -Exactly 1 -ParameterFilter { CheckAzParameters -argsFromCommand $args -azCommandPrefix "ad app list" -azCommandMidfix "displayname eq 'SCEPman-api'" }
        Should -Invoke CreateServicePrincipal -Exactly 1
        Should -Invoke SetManagedIdentityPermissions -Exactly 1 -ParameterFilter { $principalId -eq "12345678-aad6-4711-82a9-0123456789ab" -and $resourcePermissions.resourceId -eq "33335678-aad6-4711-82a9-0123456789ab" }
    }
}