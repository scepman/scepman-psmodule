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

        function MockAzAsRegistered {
            Mock az {
                return Get-Content -Path "./Tests/Data/appregistration-with-az.json"
            } -ParameterFilter { CheckAzParameters -argsFromCommand $args -azCommandPrefix "ad app show" -azCommandMidfix "--id 12345678-aad6-4711-82a9-0123456789ab" }
        }

        function AssertAzCheckApplicationWasCalled {
            Should -Invoke az -Exactly 1 -ParameterFilter { CheckAzParameters -argsFromCommand $args -azCommandPrefix "ad app show" -azCommandMidfix "--id 12345678-aad6-4711-82a9-0123456789ab" }
        }

        Mock az {
            throw "Unexpected parameter for az: $args (with array values $($args[0]), $($args[1]), ... -- #$($args.Count) in total)"
        }

        function ExtractBodyFromArgs ($argsFromCommand) {
            if ($argsFromCommand[0].Count -gt 1) {  # Sometimes the args are passed as an array as the first element of the args array. Sometimes they are the first array directly
                $argsFromCommand = $argsFromCommand[0]
            }

            $bodyIndex = $argsFromCommand.IndexOf("--body")
            if ($bodyIndex -eq -1) {
                throw "No body found in az command"
            }
            $jsonBody = $argsFromCommand[$bodyIndex + 1]
            $jsonBody | Should -Not -BeNullOrEmpty
            return ConvertFrom-Json $jsonBody
        }
    }

    AfterEach {
        AssertAzCheckApplicationWasCalled
    }

    It "registers as Trusted Application" {
        # Arrange
        MockAzAsUnregistered
        Mock az {
            $body = ExtractBodyFromArgs -argsFromCommand $args
            $body.api.preAuthorizedApplications.appId | Should -Be $AzAppId
        } -ParameterFilter { CheckAzParameters -argsFromCommand $args -azCommandPrefix "rest --method patch" -azCommandMidfix "applications/" }

        # Act
        $bResult = Add-AzAsTrustedClientApplication -AppId "12345678-aad6-4711-82a9-0123456789ab"

        # Assert
        $bResult | Should -Be $true
        Should -Invoke az -Exactly 1 -ParameterFilter { CheckAzParameters -argsFromCommand $args -azCommandPrefix "rest --method patch" -azCommandMidfix "applications/" }
    }

    It "skips registration if az is already there " {
        # Arrange
        MockAzAsRegistered

        # Act
        $bResult = Add-AzAsTrustedClientApplication -AppId "12345678-aad6-4711-82a9-0123456789ab"

        # Assert
        $bResult | Should -Be $false
        Should -Invoke az -Exactly 0 -ParameterFilter { CheckAzParameters -argsFromCommand $args -azCommandPrefix "rest --method patch" }
    }

    It "unregisters az" {
        # Arrange
        MockAzAsRegistered
        Mock az {
            $body = ExtractBodyFromArgs -argsFromCommand $args
            $body.api.preAuthorizedApplications | Where-Object { $_.appId -eq $AzAppId } | Should -Be $null
        } -ParameterFilter { CheckAzParameters -argsFromCommand $args -azCommandPrefix "rest --method patch" -azCommandMidfix "applications/" }

        # Act
        Remove-AzAsTrustedClientApplication -AppId "12345678-aad6-4711-82a9-0123456789ab"

        # Assert
        Should -Invoke az -Exactly 1 -ParameterFilter { CheckAzParameters -argsFromCommand $args -azCommandPrefix "rest --method patch" -azCommandMidfix "applications/" }
    }
}