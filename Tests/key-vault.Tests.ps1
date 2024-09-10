BeforeAll {
    . $PSScriptRoot/../SCEPman/Private/az-commands.ps1
    . $PSScriptRoot/../SCEPman/Private/key-vault.ps1

    . $PSScriptRoot/test-helpers.ps1
}

Describe 'Key Vault' {
    It 'generates a reasonable RSA Default Policy' {
        $policy = Get-RsaDefaultPolicy
        $policy.policy.key_props.kty | Should -Be "RSA-HSM"
        $policy.policy.key_props.key_size | Should -BeGreaterOrEqual 2048

        $policy.policy.x509_props.key_usage | Should -Contain "cRLSign" -Because "This is a required for a CA certificate"
        $policy.policy.x509_props.key_usage | Should -Contain "keyCertSign" -Because "This is a required for a CA certificate"

        $policy.policy.x509_props.key_usage | Should -Contain "digitalSignature" -Because "This is required for a SCEP certificate"
        $policy.policy.x509_props.key_usage | Should -Contain "keyEncipherment" -Because "This is required for a SCEP certificate"

        $policy.policy.x509_props.validity_months | Should -BeGreaterOrEqual 60 -Because "CAs should be valid for some time"

        $policy.policy.x509_props.basic_constraints.ca | Should -Be $true -Because "This is a CA certificate"

        $policy.policy.key_props.exportable | Should -Be $false -Because "For security reasons"
        $policy.policy.key_props.reuse_key | Should -Be $false -Because "It is usually the first certificate"
    }

    Context "When a Policy has been Configured" {
        BeforeEach {
            $policy = Get-RsaDefaultPolicy
            $policy.policy.x509_props.subject += ",O=Test Organization"

            Mock ExecuteAzCommandRobustly {
                param($azCommand, [switch]$callAzNatively)

                return '{ "val": "x", "request_id": "123", "csr": "-----BEGIN CERTIFICATE REQUEST-----"}'
            }
        }

        It 'Generates a CSR' {
            $csr = New-IntermediateCaCsr -vaultUrl "https://test.vault.azure.net" -certificateName "test-certificate" -policy $policy
            $csr | Should -Match "-----BEGIN CERTIFICATE REQUEST-----"

            Should -Invoke ExecuteAzCommandRobustly -Exactly 1 -ParameterFilter { $azCommand.Where( { $_.StartsWith('https') }) -like "*/create*" }
        }
    }

    It 'adds permissions' {
        # Arrange
        Mock az {
            if (CheckAzParameters -argsFromCommand $args -azCommandMidfix "--key-permissions" -azCommandSuffix 'get create unwrapKey sign') {
                return '[]'
            }
            if (CheckAzParameters -argsFromCommand $args -azCommandMidfix "--secret-permissions" -azCommandSuffix 'get list set delete') {
                return '[]'
            }
            if (CheckAzParameters -argsFromCommand $args -azCommandMidfix "--certificate-permissions" -azCommandSuffix 'get list create managecontacts') {
                return '[]'
            }

            throw "Unexpected set of permissions set on Key Vault: $args (with array values $($args[0]) [$($args[0].GetType())], $($args[1]), ... -- #$($args.Count) in total)"

          } -ParameterFilter { CheckAzParameters -argsFromCommand $args -azCommandPrefix 'keyvault set-policy' }
        
        Mock az {
            throw "Unexpected parameter for az: $args (with array values $($args[0]) [$($args[0].GetType())], $($args[1]), ... -- #$($args.Count) in total)"
        }

        $keyvault = @{ SubscriptionId = "83804974-c230-4240-b384-0c4d3b7ef201"; name = "test-kv-name"; properties_enableRbacAuthorization = $null }

        # Act
        AddSCEPmanPermissionsToKeyVault -KeyVault $keyvault -PrincipalId "ea63b5f9-3fb8-4494-a83b-9cb7d3e48793"

        # Assert
        Should -Invoke az -Exactly 3
    }

    It 'adds RBAC permissions' {
        # Arrange
        $keyVaultId = "/subscriptions/83804974-c230-4240-b384-0c4d3b7ef201/resourceGroups/test-rg/providers/Microsoft.KeyVault/vaults/test-kv-name"

        Mock az {
            if (CheckAzParameters -argsFromCommand $args -azCommandMidfix "Key Vault Crypto Officer") {
                return '[]'
            }
            if (CheckAzParameters -argsFromCommand $args -azCommandMidfix "Key Vault Certificates Officer") {
                return '[]'
            }
            if (CheckAzParameters -argsFromCommand $args -azCommandMidfix "Key Vault Secrets User") {
                return '[]'
            }

            throw "Unexpected set of permissions set on Key Vault: $args (with array values $($args[0]) [$($args[0].GetType())], $($args[1]), ... -- #$($args.Count) in total)"

          } -ParameterFilter { CheckAzParameters -argsFromCommand $args -azCommandPrefix 'role assignment create' -azCommandSuffix $keyVaultId }
        
        Mock az {
            throw "Unexpected parameter for az: $args (with array values $($args[0]) [$($args[0].GetType())], $($args[1]), ... -- #$($args.Count) in total)"
        }

        $keyvault = @{ SubscriptionId = "83804974-c230-4240-b384-0c4d3b7ef201"; name = "test-kv-name"; properties_enableRbacAuthorization = $true; id = $keyVaultId }

        # Act
        AddSCEPmanPermissionsToKeyVault -KeyVault $keyvault -PrincipalId "ea63b5f9-3fb8-4494-a83b-9cb7d3e48793"

        # Assert
        Should -Invoke az -Exactly 3
    }
}