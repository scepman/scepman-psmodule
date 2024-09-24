BeforeAll {
    . $PSScriptRoot/../SCEPman/Private/az-commands.ps1
    . $PSScriptRoot/../SCEPman/Private/appregistrations.ps1
    . $PSScriptRoot/../SCEPman/Private/permissions.ps1
    . $PSScriptRoot/../Tests/test-helpers.ps1
}

Describe 'RegisterAzureADApp' {
    BeforeAll {
        Mock az {
            return $(Get-Content -Path "./Tests/Data/version.json")
        } -ParameterFilter { CheckAzParameters -argsFromCommand $args -azCommandPrefix "version" }
    }

    It 'can successfully fetch an app registration if one already exists' {
        Mock az {
            return Get-Content -Path "./Tests/Data/applist.json"
        } -ParameterFilter { CheckAzParameters -argsFromCommand $args -azCommandPrefix "ad app list" }

        $result = RegisterAzureADApp -name "display-name"
        $appregsJson = (Get-Content -Path "./Tests/Data/applist.json")
        $appregs = Convert-LinesToObject $appregsJson
        $result.ToString() | Should -Be $appregs[0].ToString()
    }

    It 'can successfully create if one does not exist' {
        Mock az {
            return $()
        } -ParameterFilter { CheckAzParameters -argsFromCommand $args -azCommandPrefix "ad app list" }
        Mock az {
            return $(Get-Content -Path "./Tests/Data/applist.json")
        } -ParameterFilter { CheckAzParameters -argsFromCommand $args -azCommandPrefix "ad app create" }

        RegisterAzureADApp 
        Should -Invoke -CommandName az -ParameterFilter { CheckAzParameters -argsFromCommand $args -azCommandPrefix "ad app create" }
    }

    It 'throws an error if CreateIfNotExists is false and app registration does not exist' {
        Mock az {
            return $()
        } -ParameterFilter { CheckAzParameters -argsFromCommand $args -azCommandPrefix "ad app list" }
        Mock az {
            return $(Get-Content -Path "./Tests/Data/applist.json")
        } -ParameterFilter { CheckAzParameters -argsFromCommand $args -azCommandPrefix "ad app create" }

        { RegisterAzureADApp -name "existing-app" -createIfNotExists $false } | Should -Throw
    }


    It 'throws an error if app registration creation fails' {
        Mock az {
            throw "Failed to create app registration"
        } -ParameterFilter { CheckAzParameters -argsFromCommand $args -azCommandPrefix "ad app create" }

        { RegisterAzureADApp -name "new-app" } | Should -Throw
    }

    It 'throws an error if app registration retrieval fails' {
        Mock az {
            throw "Failed to retrieve app registration"
        } -ParameterFilter { CheckAzParameters -argsFromCommand $args -azCommandPrefix "ad app list" }
        { RegisterAzureADApp -name "existing-app" } | Should -Throw
    }
}

Describe 'Create SCEPman App Registrations' {
    BeforeAll {
        #Az calls in create ScepmanAppRegistration
        Mock az {
            return $null
        } -ParameterFilter { CheckAzParameters -argsFromCommand $args -azCommandPrefix "ad app update" }
        Mock az {
            return $null
        } -ParameterFilter { CheckAzParameters -argsFromCommand $args -azCommandPrefix "rest" }
        Mock az {
            throw "Unexpected Command: $args"
        }

        Mock RegisterAzureADApp { 
            return $(Convert-LinesToObject $(Get-Content -Path "./Tests/Data/applist.json"))[0]
        }

        Mock CreateServicePrincipal {
            return "ID"
        }

        Mock SetManagedIdentityPermissions {
            return $null
        }
    }

    It 'calls RegisterAzureADApp' {
        CreateSCEPmanAppRegistration -AzureADAppNameForSCEPman 'appname' -CertMasterServicePrincipalId 'id' -GraphBaseUri 'uri'
        Should -Invoke RegisterAzureADApp
    }

    It 'has expected output' {
        $result = CreateSCEPmanAppRegistration -AzureADAppNameForSCEPman 'appname' -CertMasterServicePrincipalId 'id' -GraphBaseUri 'uri'
        $result.ToString() | Should -Be $(Convert-LinesToObject $(Get-Content -Path "./Tests/Data/applist.json"))[0].ToString()
    }

    It 'should throw an error if no CSR.Request role exists' {
        Mock RegisterAzureADApp { 
            return $(Convert-LinesToObject $(Get-Content -Path "./Tests/Data/applist-norole.json"))[0]
        }
        {CreateSCEPmanAppRegistration -AzureADAppNameForSCEPman 'appname' -CertMasterServicePrincipalId 'id' -GraphBaseUri 'uri'} | Should -Throw
    }
}

Describe 'Create Cert Master App Registrations' {
    BeforeAll {
        #Az calls in create ScepmanAppRegistration
        Mock az {
            return $null
        } -ParameterFilter { CheckAzParameters -argsFromCommand $args -azCommandPrefix "ad app update" }
        Mock az {
            return $null
        } -ParameterFilter { CheckAzParameters -argsFromCommand $args -azCommandPrefix "rest" }

        #Az calls in create CertMasterAppRegistration
        Mock az { # for permission list, permission grant, permission add calls (all can return null for now)
            return $null
        } -ParameterFilter { CheckAzParameters -argsFromCommand $args -azCommandPrefix "ad app permission" }
        Mock az {
            return $(Get-Content -Path "./Tests/Data/version.json")
        } -ParameterFilter { CheckAzParameters -argsFromCommand $args -azCommandPrefix "version" }
        Mock az {
            throw "Unexpected Command: $args"
        }

        Mock RegisterAzureADApp { 
            return $(Convert-LinesToObject $(Get-Content -Path "./Tests/Data/applist.json"))[0]
        }

        Mock CreateServicePrincipal {
            return "ID"
        }
    }

    It 'calls RegisterAzureADApp' {
        CreateCertMasterAppRegistration -AzureADAppNameForCertMaster 'appname' -CertMasterBaseURLs 'https://scepman-cm.com'
        Should -Invoke RegisterAzureADApp
    }
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
