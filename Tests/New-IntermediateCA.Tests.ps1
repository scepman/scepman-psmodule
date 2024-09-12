BeforeAll {
    . $PSScriptRoot/../SCEPman/Private/az-commands.ps1
    . $PSScriptRoot/../SCEPman/Private/key-vault.ps1

    . $PSScriptRoot/test-helpers.ps1
}

Describe 'Intermediate CA' {
    BeforeEach {
        . $PSScriptRoot/../SCEPman/Public/New-IntermediateCA.ps1
    }

    It "applies the organisation to the policy" {
        Reset-IntermediateCaPolicy -Organization "Test Organization"

        $policy = Get-IntermediateCaPolicy

        $policy | Should -Not -BeNullOrEmpty
        $policy.policy.x509_props.subject | Should -Match "CN=SCEPman Intermediate CA"
        $policy.policy.x509_props.subject | Should -Match "O=Test Organization"
    }

    Describe 'New-IntermediateCA' {
        It "lets you set and get the policy" {
            $policy = Get-IntermediateCaPolicy
    
            $policy.policy.issuer.name = "self-signed"
    
            Set-IntermediateCaPolicy -Policy $policy
    
            $policy2 = Get-IntermediateCaPolicy
            $policy2 | Should -Be $policy
        }
    
        It 'creates a CSR' {
            # Arrange
            function GetSubscriptionDetails ([bool]$SearchAllSubscriptions, $SubscriptionId, $AppServiceName, $AppServicePlanName) { }  # Mocked
            function ReadAppSetting($AppServiceName, $ResourceGroup, $SettingName, $Slot = $null) { } # Mocked

            $testKeyVaultUrl = "https://test.vault.azure.net"
            $certificateName = "test-certificate"

            MockAzVersion
            Mock AzLogin {
                return $null
            }
            Mock GetSubscriptionDetails {
                return @{
                    "name" = "Test Subscription"
                    "tenantId" = "123"
                }
            }
            Mock ReadAppSetting {
                return $testKeyVaultUrl
            } -ParameterFilter { $SettingName -eq "AppConfig:KeyVaultConfig:KeyVaultURL" }
            Mock ReadAppSetting {
                return $certificateName
            } -ParameterFilter { $SettingName -eq "AppConfig:KeyVaultConfig:RootCertificateConfig:CertificateName" }
            Mock az {
                return '{ "val": "x", "request_id": "123", "csr": "-----BEGIN CERTIFICATE REQUEST-----"}'
            } -ParameterFilter { CheckAzParameters -argsFromCommand $args -azCommandPrefix "rest --method post" -azCommandMidfix "$testKeyVaultUrl/certificates/$certificateName/create" }
            Mock az {
                throw "Unexpected parameter for az: $args (with array values $($args[0]) [$($args[0].GetType())], $($args[1]), ... -- #$($args.Count) in total)"
            }

            # Act
            $csr = New-IntermediateCA -SCEPmanAppServiceName "as-scepman-test" -SCEPmanResourceGroup "rg-scepman-test"

            # Assert
            $csr | Should -Match "-----BEGIN CERTIFICATE REQUEST-----"

            Should -Invoke AzLogin -Exactly 1
            Should -Invoke GetSubscriptionDetails -Exactly 1
            Should -Invoke ReadAppSetting -Exactly 2
            Should -Invoke az -Exactly 1 -ParameterFilter { CheckAzParameters -argsFromCommand $args -azCommandPrefix "rest --method post" }
        }
    }
}