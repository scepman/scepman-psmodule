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
