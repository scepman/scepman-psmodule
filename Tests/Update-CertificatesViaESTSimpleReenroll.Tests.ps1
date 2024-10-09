BeforeAll {
    . $PSScriptRoot/../SCEPman/Public/Update-CertificatesViaESTSimpleReenroll.ps1
}

Describe 'Update-CertificatesViaESTSimpleReenroll' -Skip:(-not $IsWindows) {
    It 'Fails if both -user and -machine are specified' {
        { Update-CertificatesViaESTSimpleReenroll -AppServiceUrl "https://test.com" -User -Machine } | Should -Throw 'You must specify either -User or -Machine.'
    }

    It 'Fails if neither -user nor -machine are specified' {
        { Update-CertificatesViaESTSimpleReenroll -AppServiceUrl "https://test.com" } | Should -Throw 'You must specify either -User or -Machine.'
    }

    Context 'With temporary certificate creation' {

        It 'Renews each certificate that is found' {
            Mock GetSCEPmanCerts {
                return @(
                    New-SelfSignedCertificate -Subject "CN=Cert1,OU=PesterTest" -KeyAlgorithm 'RSA' -KeyLength 512
                    New-SelfSignedCertificate -Subject "CN=Cert2,OU=PesterTest" -KeyAlgorithm 'RSA' -KeyLength 512
                )
            }

            Mock RenewCertificateMTLS {
                param($Certificate, $AppServiceUrl, [switch]$User, [switch]$Machine)

                $Certificate.Subject | Should -Match "OU=PesterTest"
                $User | Should -Be $true
                $Machine | Should -Be $false
                $AppServiceUrl | Should -Be "https://test.com"
            }

            Update-CertificatesViaESTSimpleReenroll -AppServiceUrl "https://test.com" -User

            Should -Invoke -CommandName RenewCertificateMTLS -Exactly 2
        }
    }

    AfterEach {
            # Clean up test certificates
        $pesterTestCerts = Get-Item -Path Cert:\CurrentUser\My\* | Where-Object { $_.Subject.Contains("OU=PesterTest") }
        $pesterTestCerts | Remove-Item -Force
    }
}