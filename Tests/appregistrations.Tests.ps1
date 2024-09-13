BeforeAll {
    . $PSScriptRoot/../SCEPman/Private/constants.ps1
    . $PSScriptRoot/../SCEPman/Private/az-commands.ps1
    . $PSScriptRoot/../SCEPman/Private/appregistrations.ps1

    . $PSScriptRoot/test-helpers.ps1
}

Describe "az as app registration" {
    BeforeAll {
        function MockAzAsUnregistered {
            Mock az {
                return Get-Content -Path "./Tests/Data/appregistration-without-az.json"
            } -ParameterFilter { CheckAzParameters -argsFromCommand $args -azCommandPrefix "ad app show" -azCommandMidfix "--id 12345678-aad6-4711-82a9-0123456789ab" }
        }

        function AssertAzAsUnregisteredWasCalled {
            Should -Invoke az -Exactly 1 -ParameterFilter { CheckAzParameters -argsFromCommand $args -azCommandPrefix "ad app show" -azCommandMidfix "--id 12345678-aad6-4711-82a9-0123456789ab" }
        }
    }

    It "registers as Trusted Application" {
        # Arrange
        MockAzAsUnregistered
        Mock az {
            $bodyIndex = $args.IndexOf("--body") + 1
            $body = ConvertFrom-Json $args[$bodyIndex]
            $body.api.preAuthorizedApplications.appId | Should -Be $AzAppId
        } -ParameterFilter { CheckAzParameters -argsFromCommand $args -azCommandPrefix "rest --method patch" -azCommandMidfix "applications/12345678-aad6-4711-82a9-0123456789ab" }

        # Act
        $bResult = Add-AzAsTrustedClientApplication -AppId "12345678-aad6-4711-82a9-0123456789ab"

        # Assert
        $bResult | Should -Be $true
        AssertAzAsUnregisteredWasCalled
    }
}