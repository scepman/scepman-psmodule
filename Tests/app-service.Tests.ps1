BeforeAll {
    . $PSScriptRoot/../SCEPman/Private/constants.ps1
    . $PSScriptRoot/../SCEPman/Private/az-commands.ps1
    . $PSScriptRoot/../SCEPman/Private/app-service.ps1

    . $PSScriptRoot/test-helpers.ps1
}

Describe 'App Service' {
    BeforeAll {
        EnsureNoAdditionalAzCalls
    }

    Context 'SelectBestDotNetRuntime' {
        It 'Finds a good Windows DotNet Runtime' {
            Mock Invoke-Az {
                return @(
                    "dotnet:10",
                    "dotnet:9",
                    "ASPNET:V4.8",
                    "NODE:20LTS"
                )
            } -ParameterFilter { $azCommand -join ' ' -eq 'webapp list-runtimes --os windows --output tsv' }

            $runtime = SelectBestDotNetRuntime

            $runtime | Should -Be "dotnet:10"
            Should -Invoke Invoke-Az -Exactly 1 -ParameterFilter { $azCommand -join ' ' -eq 'webapp list-runtimes --os windows --output tsv' }
        }

        It 'Finds a good Linux DotNet Runtime' {
            Mock Invoke-Az {
                return @(
                    "DOTNETCORE:10.0",
                    "DOTNETCORE:9.0",
                    "NODE:20-lts"
                )
            } -ParameterFilter { $azCommand -join ' ' -eq 'webapp list-runtimes --os linux --output tsv' }

            $runtime = SelectBestDotNetRuntime -ForLinux $true

            $runtime | Should -Be "DOTNETCORE:10.0"
        }

        It 'Falls back to the default runtime if no matching runtime is returned' -ForEach @(
            @{ ForLinux = $false; ExpectedRuntime = 'dotnet:10'; Os = 'windows'; NonDotNetRuntime = 'NODE:20LTS' }
            @{ ForLinux = $true; ExpectedRuntime = 'DOTNETCORE:10.0'; Os = 'linux'; NonDotNetRuntime = 'NODE:20-lts' }
        ) {
            Mock Invoke-Az { return @($NonDotNetRuntime) } -ParameterFilter { $azCommand -join ' ' -eq "webapp list-runtimes --os $Os --output tsv" }

            $runtime = SelectBestDotNetRuntime -ForLinux $ForLinux

            $runtime | Should -Be $ExpectedRuntime
        }

        It 'Falls back to the default runtime if runtime retrieval fails' -ForEach @(
            @{ ForLinux = $false; ExpectedRuntime = 'dotnet:10'; Os = 'windows' }
            @{ ForLinux = $true; ExpectedRuntime = 'DOTNETCORE:10.0'; Os = 'linux' }
        ) {
            Mock Invoke-Az { throw 'az failed' } -ParameterFilter { $azCommand -join ' ' -eq "webapp list-runtimes --os $Os --output tsv" }

            $runtime = SelectBestDotNetRuntime -ForLinux $ForLinux

            $runtime | Should -Be $ExpectedRuntime
        }
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

    Describe 'App Service Plan' {
        It 'Detects <Platform> App Service Plans' -ForEach @(
            @{ Platform = 'Linux';   Kind = 'linux'; Expected = $true }
            @{ Platform = 'Windows'; Kind = 'app';   Expected = $false }
        ) {
            Mock az { return $Kind } -ParameterFilter { CheckAzParameters -argsFromCommand $args -azCommandPrefix "appservice plan show" }

            $isAspLinux = IsAppServicePlanLinux -AppServicePlanId "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.Web/serverfarms/asp-test"

            $isAspLinux | Should -Be $Expected
        }
    }

    Context 'New-CertMasterAppService' {
        BeforeAll {
            # Mock finding the SCEPman App Service
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
        }

        BeforeEach {
            $CacheAppServiceKinds.Clear()
        }

        It 'Works when CertMaster is already installed' {
            Mock az { return 'app' } -ParameterFilter { CheckAzParameters -argsFromCommand $args -azCommandPrefix 'webapp show' -azCommandSuffix '--output tsv' -azCommandMidfix "--query kind" }
            Mock GetCertMasterAppServiceName { return "as-scepman-cm" }

            $certMaster = New-CertMasterAppService -SCEPmanResourceGroup "rg-scepman-test" -SCEPmanAppServiceName "as-scepman" -CertMasterResourceGroup "rg-certmaster" -TenantId "00000000-0000-1234-0000-000000000000"

            $certMaster | Should -Be "as-scepman-cm"
        }

        It 'Installs CertMaster on <Platform>' -ForEach @(
            @{ Platform = 'Windows'; Kind = 'app';       ArtifactFragment = 'CertMaster-Artifacts.zip' }
            @{ Platform = 'Linux';   Kind = 'app,linux';  ArtifactFragment = 'CertMaster-Artifacts-Linux.zip' }
        ) {
            Mock az { return $Kind } -ParameterFilter { CheckAzParameters -argsFromCommand $args -azCommandPrefix 'webapp show' -azCommandSuffix '--output tsv' -azCommandMidfix "--query kind" }
            Mock GetCertMasterAppServiceName { return $null }
            Mock Read-Host { return "as-scepman-cm" } -ParameterFilter { ($Prompt -join '').Contains("enter the name") }
            Mock az { return "excellent!" } -ParameterFilter { CheckAzParameters -argsFromCommand $args -azCommandPrefix 'webapp create' -azCommandMidfix "--name as-scepman-cm" }
            Mock az { return $null } -ParameterFilter { CheckAzParameters -argsFromCommand $args -azCommandPrefix 'webapp config appsettings set' -azCommandMidfix "--name as-scepman-cm" }
            Mock az { return $null } -ParameterFilter { CheckAzParameters -argsFromCommand $args -azCommandPrefix 'webapp config set' -azCommandMidfix "--name as-scepman-cm" }

            # Act
            $certMaster = New-CertMasterAppService -SCEPmanResourceGroup "rg-scepman-test" -SCEPmanAppServiceName "as-scepman" -CertMasterResourceGroup "rg-certmaster" -TenantId "00000000-0000-1234-0000-000000000000"

            # Assert
            $certMaster | Should -Be "as-scepman-cm"
            Should -Invoke az -Exactly 1 -ParameterFilter { CheckAzParameters -argsFromCommand $args -azCommandPrefix 'webapp create' -azCommandMidfix "--name as-scepman-cm" }
            Should -Invoke az -Exactly 1 -ParameterFilter { CheckAzParameters -argsFromCommand $args -azCommandPrefix 'webapp config appsettings set' -azCommandMidfix $ArtifactFragment }
            Should -Invoke az -Exactly 1 -ParameterFilter { CheckAzParameters -argsFromCommand $args -azCommandPrefix 'webapp config set' -azCommandMidfix "--name as-scepman-cm" }
        }
    }

    Context 'Update-ToConfiguredChannel' {
        BeforeEach {
            $CacheAppServiceKinds.Clear()
        }

        It 'Switches to correct <Platform> artifact URL' -ForEach @(
            @{ Platform = 'Windows'; Kind = 'app';       ArtifactFragment = 'Artifacts-Beta.zip' }
            @{ Platform = 'Linux';   Kind = 'app,linux';  ArtifactFragment = 'Artifacts-Linux-Beta.zip' }
        ) {
            Mock az { return "beta" } -ParameterFilter { CheckAzParameters -argsFromCommand $args -azCommandPrefix 'webapp config appsettings list' -azCommandMidfix "Update_Channel" }
            Mock az { return $Kind } -ParameterFilter { CheckAzParameters -argsFromCommand $args -azCommandPrefix 'webapp show' -azCommandSuffix '--output tsv' -azCommandMidfix "--query kind" }
            Mock az { return $null } -ParameterFilter { CheckAzParameters -argsFromCommand $args -azCommandPrefix 'webapp config appsettings set' }
            Mock az { return $null } -ParameterFilter { CheckAzParameters -argsFromCommand $args -azCommandPrefix 'webapp config appsettings delete' }

            Update-ToConfiguredChannel -AppServiceName "as-scepman" -ResourceGroup "rg-scepman-test" -ChannelArtifacts $Artifacts_Scepman

            Should -Invoke az -Exactly 1 -ParameterFilter { CheckAzParameters -argsFromCommand $args -azCommandPrefix 'webapp config appsettings set' -azCommandMidfix $ArtifactFragment }
        }
    }

    Context 'Confirm-ArtifactPlatform' {
        It 'Returns true for known channel and matching <Platform> artifact URL' -ForEach @(
            @{ Platform = 'Windows'; LinuxFlag = $false; ArtifactPlatform = 'windows' }
            @{ Platform = 'Linux'; LinuxFlag = $true; ArtifactPlatform = 'linux' }
        ) {
            $artifactUrl = $Artifacts_Scepman[$ArtifactPlatform].beta
            Mock ReadAppSetting { return $ArtifactUrl }
            Mock IsAppServiceLinux { return $LinuxFlag }

            $result = Confirm-ArtifactPlatform -AppServiceName "as-scepman" -ResourceGroup "rg-scepman-test" -ChannelArtifacts $Artifacts_Scepman

            $result | Should -Be $true
            Should -Invoke ReadAppSetting -Exactly 1
            Should -Invoke IsAppServiceLinux -Exactly 1
        }

        It 'Returns false for unknown artifact URL' {
            Mock ReadAppSetting { return 'https://example.invalid/manual-package.zip' }
            Mock IsAppServiceLinux { return $false }

            $result = Confirm-ArtifactPlatform -AppServiceName "as-scepman" -ResourceGroup "rg-scepman-test" -ChannelArtifacts $Artifacts_Scepman

            $result | Should -Be $false
        }

        It 'Switches artifact URL when known channel does not match platform' {
            Mock ReadAppSetting { return $Artifacts_Scepman.windows.beta }
            Mock IsAppServiceLinux { return $true }
            Mock ExecuteAzCommandRobustly { return $null } -ParameterFilter {
                $callAzNatively -and (CheckAzParameters -argsFromCommand $azCommand -azCommandPrefix 'webapp config appsettings set' -azCommandMidfix "WEBSITE_RUN_FROM_PACKAGE=$($Artifacts_Scepman.linux.beta)")
            }

            Confirm-ArtifactPlatform -AppServiceName "as-scepman" -ResourceGroup "rg-scepman-test" -ChannelArtifacts $Artifacts_Scepman

            Should -Invoke ExecuteAzCommandRobustly -Exactly 1 -ParameterFilter {
                $callAzNatively -and (CheckAzParameters -argsFromCommand $azCommand -azCommandPrefix 'webapp config appsettings set' -azCommandMidfix "WEBSITE_RUN_FROM_PACKAGE=$($Artifacts_Scepman.linux.beta)")
            }
        }
    }

    Context 'Confirm-AppServiceStack' {
        It 'Sets the stack when no stack is configured' {
            Mock IsAppServiceLinux { return $false }
            Mock SelectBestDotNetRuntime { return 'dotnet:10' }
            Mock Invoke-Az { return $null } -ParameterFilter { $azCommand -join ' ' -eq 'webapp config show --name as-scepman --resource-group rg-scepman-test --query netFrameworkVersion --output tsv' }
            Mock Set-AppServiceStack {}

            Confirm-AppServiceStack -AppServiceName 'as-scepman' -ResourceGroup 'rg-scepman-test'

            Should -Invoke Set-AppServiceStack -Exactly 1 -ParameterFilter { $AppServiceName -eq 'as-scepman' -and $ResourceGroup -eq 'rg-scepman-test' -and $Stack -eq 'dotnet:10' }
        }

        It 'Does not change the stack when the configured version already matches' -ForEach @(
            @{ Platform = 'Windows'; LinuxFlag = $false; IntendedStack = 'dotnet:10'; ActualStack = 'v10.0'; Query = 'netFrameworkVersion' }
            @{ Platform = 'Linux'; LinuxFlag = $true; IntendedStack = 'DOTNETCORE:10.0'; ActualStack = 'DOTNETCORE|10.0'; Query = 'linuxFxVersion' }
        ) {
            Mock IsAppServiceLinux { return $LinuxFlag }
            Mock SelectBestDotNetRuntime { return $IntendedStack }
            Mock Invoke-Az { return $ActualStack } -ParameterFilter { $azCommand -join ' ' -eq "webapp config show --name as-scepman --resource-group rg-scepman-test --query $Query --output tsv" }
            Mock Set-AppServiceStack {}

            Confirm-AppServiceStack -AppServiceName 'as-scepman' -ResourceGroup 'rg-scepman-test'

            Should -Invoke Set-AppServiceStack -Exactly 0
        }

        It 'Updates the stack when the configured version is lower than intended' {
            Mock IsAppServiceLinux { return $true }
            Mock SelectBestDotNetRuntime { return 'DOTNETCORE:10.0' }
            Mock Invoke-Az { return 'DOTNETCORE|9.0' } -ParameterFilter { $azCommand -join ' ' -eq 'webapp config show --name as-scepman --resource-group rg-scepman-test --query linuxFxVersion --output tsv' }
            Mock Set-AppServiceStack {}

            Confirm-AppServiceStack -AppServiceName 'as-scepman' -ResourceGroup 'rg-scepman-test'

            Should -Invoke Set-AppServiceStack -Exactly 1 -ParameterFilter { $Stack -eq 'DOTNETCORE:10.0' }
        }

        It 'Does not downgrade the stack when the configured version is higher than intended' {
            Mock IsAppServiceLinux { return $false }
            Mock SelectBestDotNetRuntime { return 'dotnet:10' }
            Mock Invoke-Az { return 'v11.0' } -ParameterFilter { $azCommand -join ' ' -eq 'webapp config show --name as-scepman --resource-group rg-scepman-test --query netFrameworkVersion --output tsv' }
            Mock Set-AppServiceStack {}

            Confirm-AppServiceStack -AppServiceName 'as-scepman' -ResourceGroup 'rg-scepman-test'

            Should -Invoke Set-AppServiceStack -Exactly 0
        }

        It 'Skips the stack update if the configured stack format cannot be parsed' {
            Mock IsAppServiceLinux { return $false }
            Mock SelectBestDotNetRuntime { return 'dotnet:10' }
            Mock Invoke-Az { return 'this-is-not-a-version' } -ParameterFilter { $azCommand -join ' ' -eq 'webapp config show --name as-scepman --resource-group rg-scepman-test --query netFrameworkVersion --output tsv' }
            Mock Set-AppServiceStack {}

            Confirm-AppServiceStack -AppServiceName 'as-scepman' -ResourceGroup 'rg-scepman-test'

            Should -Invoke Set-AppServiceStack -Exactly 0
        }
    }

    Context 'Set-AppServiceStack' {
        It 'Sets the requested runtime on the app service' {
            Mock Invoke-Az { return $null } -ParameterFilter { $azCommand -join ' ' -eq 'webapp config set --name as-scepman --resource-group rg-scepman-test --runtime DOTNETCORE:10.0' }

            Set-AppServiceStack -AppServiceName 'as-scepman' -ResourceGroup 'rg-scepman-test' -Stack 'DOTNETCORE:10.0'

            Should -Invoke Invoke-Az -Exactly 1 -ParameterFilter { $azCommand -join ' ' -eq 'webapp config set --name as-scepman --resource-group rg-scepman-test --runtime DOTNETCORE:10.0' }
        }
    }
}