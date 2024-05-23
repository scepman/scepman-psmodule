BeforeAll {
    . $PSScriptRoot/../SCEPman/Private/key-vault.ps1
}

Describe 'Key Vault' {
    It 'RSA Default Policy should be reasonable' {
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
}