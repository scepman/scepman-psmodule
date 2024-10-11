BeforeAll {
    . $PSScriptRoot/../SCEPman/Private/constants.ps1
    . $PSScriptRoot/../SCEPman/Private/az-commands.ps1
    . $PSScriptRoot/../SCEPman/Private/app-service.ps1

    . $PSScriptRoot/test-helpers.ps1
}

Describe 'App Service' {
    BeforeAll {
        Mock az {
            throw "Unexpected parameter for az: $args (with array values $($args[0]), $($args[1]), ... -- #$($args.Count) in total)"
        }
    }

    It 'Finds a good DotNet Runtime' {

        Mock Invoke-Az {
            param($azCommand)

            if ($azCommand[0] -ne 'webapp' -or $azCommand[1] -ne 'list-runtimes' -or $azCommand[2] -ne '--os' -or $azCommand[3] -ne 'windows')
            {
                throw "Unexpected command: $azCommand"
            }

            return @(
                "dotnet:8",
                "dotnet:7",
                "dotnet:6",
                "ASPNET:V4.8",
                "ASPNET:V3.5",
                "NODE:20LTS",
                "NODE:18LTS",
                "NODE:16LTS",
                "java:1.8:Java SE:8",
                "java:11:Java SE:11",
                "java:17:Java SE:17",
                "java:1.8:TOMCAT:10.1",
                "java:11:TOMCAT:10.1",
                "java:17:TOMCAT:10.1",
                "java:1.8:TOMCAT:10.0",
                "java:11:TOMCAT:10.0",
                "java:17:TOMCAT:10.0",
                "java:1.8:TOMCAT:9.0",
                "java:11:TOMCAT:9.0",
                "java:17:TOMCAT:9.0",
                "java:1.8:TOMCAT:8.5",
                "java:11:TOMCAT:8.5",
                "java:17:TOMCAT:8.5"
            )
        }

        $runtime = SelectBestDotNetRuntime

        $runtime | Should -Be "dotnet:8"
    }

    It "Finds the Deployment Slots" {
        Mock az {
            Write-Error '/opt/az/lib/python3.11/site-packages/paramiko/pkey.py:100: CryptographyDeprecationWarning: TripleDES has been moved to cryptography.hazmat.decrepit.ciphers.algorithms.TripleDES and will be removed from this module in 48.0.0.'
            Write-Error '  "cipher": algorithms.TripleDES,'
            Write-Error '/opt/az/lib/python3.11/site-packages/paramiko/transport.py:259: CryptographyDeprecationWarning: TripleDES has been moved to cryptography.hazmat.decrepit.ciphers.algorithms.TripleDES and will be removed from this module in 48.0.0.'
            Write-Error '  "cipher": algorithms.TripleDES,'

            return Get-Content -Path "./Tests/Data/webapp-deployment-slot-list.json"
        } -ParameterFilter { CheckAzParameters -argsFromCommand $args -azCommandPrefix 'webapp deployment slot list' }

        $slots = GetDeploymentSlots -ResourceGroupName "rg-scepman-test" -AppName "as-scepman"

        $slots.Count | Should -Be 1
        $slots[0].Name | Should -Be "ds1"
    }

    Context 'New-CertMasterAppService' {
        It 'Works when CertMaster is already installed' {
            #Arrange
            Mock GetCertMasterAppServiceName {
                return "as-scepman-cm"
            }

            Mock az {
                return "{
                            'data' : {
                                'name' : 'as-scepman',
                                'properties' : {
                                    'serverFarmId' : 'subscriptionid/asp-scepman',
                                    'defaultHostName' : 'as-scepman'
                                }
                            }
                        }"
            } -ParameterFilter { CheckAzParameters -argsFromCommand $args -azCommandPrefix 'graph query -q "Resources' -azCommandMidfix "'as-scepman'"}

            # Act
            $certMaster = New-CertMasterAppService -SCEPmanResourceGroup "rg-scepman-test" -SCEPmanAppServiceName "as-scepman" -CertMasterResourceGroup "rg-certmaster" -TenantId "00000000-0000-1234-0000-000000000000"

            # Assert
            $certMaster | Should -Be "as-scepman-cm"
        }
    }
}