BeforeAll {
    . $PSScriptRoot/../SCEPman/Private/az-commands.ps1
    . $PSScriptRoot/../SCEPman/Private/key-vault.ps1
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
}