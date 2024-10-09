BeforeAll {
    . $PSScriptRoot/../SCEPman/Public/Update-CertificatesViaESTSimpleReenroll.ps1
}

Describe 'SimpleReenrollmentTools' -Skip:(-not $IsWindows) {

    Context 'Update-CertificatesViaESTSimpleReenroll' {
        It 'Fails if both -user and -machine are specified' {
            { Update-CertificatesViaESTSimpleReenroll -AppServiceUrl "https://test.com" -User -Machine } | Should -Throw 'You must specify either -User or -Machine.'
        }

        It 'Fails if neither -user nor -machine are specified' {
            { Update-CertificatesViaESTSimpleReenroll -AppServiceUrl "https://test.com" } | Should -Throw 'You must specify either -User or -Machine.'
        }
    }

    Context 'With temporary certificate creation' {

        BeforeAll {
                # Create Test certificates with a very low key length so it is fast to create
            $script:testcerts = @(
                New-SelfSignedCertificate -Subject "CN=Cert1,OU=PesterTest" -KeyAlgorithm 'RSA' -KeyLength 512 -CertStoreLocation Cert:\CurrentUser\My -NotAfter (Get-Date).AddDays(40)
                New-SelfSignedCertificate -Subject "CN=Cert2,OU=PesterTest" -KeyAlgorithm 'RSA' -KeyLength 512 -CertStoreLocation Cert:\CurrentUser\My -NotAfter (Get-Date).AddDays(41)
            )
        }

        It 'Renews each certificate that is found' {
            Mock GetSCEPmanCerts {
                return $script:testcerts
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

        Context 'GetSCEPmanCerts' {
            It 'Should find all certificates issued by the root' {
                Mock Invoke-WebRequest {
                    $certCollection = [System.Security.Cryptography.X509Certificates.X509Certificate2Collection]::new()
                    $certCollection.Add($script:testcerts[0])
                    $binCert1 = $certCollection.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Pkcs7)
                    $b64Cert1 = [Convert]::ToBase64String($binCert1)
                    $b64Cert1Bytes = [System.Text.Encoding]::ASCII.GetBytes($b64Cert1)

                    return @{
                        StatusCode = 200
                        Content = $b64Cert1Bytes
                    }
                }

                $foundCerts = GetSCEPmanCerts -AppServiceUrl "https://test.com" -User -ValidityThresholdDays 45

                $foundCerts | Should -HaveCount 1
#                $foundCerts[0].Subject | Should -Be $script:testcerts[0].Subject
            }
        }

        AfterAll {
            # Clean up test certificates
            $pesterTestCerts = Get-Item -Path Cert:\CurrentUser\My\* | Where-Object { $_.Subject.Contains("OU=PesterTest") }
            $pesterTestCerts | Remove-Item -Force
        }
    }
}