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
            BeforeAll {
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
            }

            It 'Should find all certificates issued by the root' {
                $foundCerts = GetSCEPmanCerts -AppServiceUrl "https://test.com" -User -ValidityThresholdDays 45

                $foundCerts | Should -HaveCount 1
                $foundCerts[0].Subject | Should -Be $script:testcerts[0].Subject
            }

            It 'Should not find a certificate if its still valid for long enough' {
                $foundCerts = GetSCEPmanCerts -AppServiceUrl "https://test.com" -User -ValidityThresholdDays 30

                $foundCerts | Should -HaveCount 0
            }

            It 'Should find certificates matching a text filter' {
                $foundCerts = GetSCEPmanCerts -AppServiceUrl "https://test.com" -User -ValidityThresholdDays 45 -FilterString "Cert1"

                $foundCerts | Should -HaveCount 1
                $foundCerts[0].Subject | Should -Be $script:testcerts[0].Subject
            }

            It 'Should filter out certificates that do not match a text filter' {
                $foundCerts = GetSCEPmanCerts -AppServiceUrl "https://test.com" -User -ValidityThresholdDays 45 -FilterString "Cert2"

                $foundCerts | Should -HaveCount 0
            }
        }

        AfterAll {
            # Clean up test certificates
            $pesterTestCerts = Get-Item -Path Cert:\CurrentUser\My\* | Where-Object { $_.Subject.Contains("OU=PesterTest") }
            $pesterTestCerts | Remove-Item -Force
        }
    }
}